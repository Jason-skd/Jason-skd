"""Integration tests: git log mining against a real temporary repository (offline)."""

from __future__ import annotations

import subprocess
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from main.sources.git_scan import (
    GitError,
    activity_from_dict,
    activity_to_dict,
    clone_or_refresh,
    collect_activity,
    refs_fingerprint,
)
from main.sources.language_scan import PathFilter

EMAIL = "wintor76111@gmail.com"
TZ = ZoneInfo("Asia/Shanghai")


def _git(repo: Path, *args: str, env_extra: dict[str, str] | None = None) -> None:
    import os

    env = dict(os.environ, GIT_AUTHOR_EMAIL=EMAIL, GIT_COMMITTER_EMAIL=EMAIL, **(env_extra or {}))
    subprocess.run(
        ["git", "-c", "user.name=Test", "-c", f"user.email={EMAIL}", *args],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
    )


def _commit(repo: Path, rel: str, content: str, *, date: str) -> None:
    target = repo / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    _git(repo, "add", rel)
    _git(
        repo,
        "commit",
        "-m",
        f"touch {rel}",
        env_extra={
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_DATE": date,
        },
    )


def _init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-b", "main")
    return repo


def test_collect_activity_day_bucketing_and_weights(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    # 2026-09-06T20:30:00Z -> 2026-09-07 04:30 in Asia/Shanghai
    _commit(repo, "src/app.py", "x\n" * 40, date="2026-09-06T20:30:00Z")
    _commit(repo, "src/lib.c", "y\n" * 10, date="2026-09-06T21:00:00Z")

    act = collect_activity(
        repo,
        author_emails=[EMAIL],
        since_iso="2025-01-01 00:00:00 +0000",
        tz=TZ,
        path_filter=PathFilter.for_repo(repo, []),
    )

    assert act.commit_count == 2
    assert act.commits_by_day == {"2026-09-07": 2}
    assert act.language_weights == {"Python": 40, "C": 10}


def test_collect_activity_ignores_other_authors_and_filters(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, "src/mine.py", "a\n" * 30, date="2026-09-06T20:00:00Z")
    # commit authored by someone else, inside vendor/ AND outside
    (repo / "vendor").mkdir()
    (repo / "vendor" / "v.c").write_text("v" * 500, encoding="utf-8")
    (repo / "other.c").write_text("o" * 50, encoding="utf-8")
    _git(repo, "add", "-A")
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Other",
            "-c",
            "user.email=other@example.com",
            "commit",
            "-m",
            "other",
        ],
        cwd=repo,
        check=True,
        capture_output=True,
        env={
            "GIT_AUTHOR_EMAIL": "other@example.com",
            "GIT_COMMITTER_EMAIL": "other@example.com",
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": str(tmp_path),
        },
    )

    act = collect_activity(
        repo,
        author_emails=[EMAIL],
        since_iso="2025-01-01 00:00:00 +0000",
        tz=TZ,
        path_filter=PathFilter.for_repo(repo, ["**/vendor/**"]),
    )

    assert act.commit_count == 1  # other author's commit not counted
    assert act.language_weights == {"Python": 30}  # vendor C and other.c both excluded


def test_collect_activity_skips_binary_and_unknown(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    bin_file = repo / "img.png"
    bin_file.write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00data")
    (repo / "notes.xyz").write_text("z" * 20, encoding="utf-8")
    _git(repo, "add", "-A")
    _git(
        repo,
        "commit",
        "-m",
        "bin",
        env_extra={
            "GIT_AUTHOR_DATE": "2026-09-06T20:00:00Z",
            "GIT_COMMITTER_DATE": "2026-09-06T20:00:00Z",
        },
    )

    act = collect_activity(
        repo,
        author_emails=[EMAIL],
        since_iso="2025-01-01 00:00:00 +0000",
        tz=TZ,
        path_filter=PathFilter.for_repo(repo, []),
    )

    assert act.commit_count == 1
    assert act.language_weights == {}  # binary '-' rows and unknown ext skipped


def test_collect_activity_all_branches(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, "main.py", "m\n" * 5, date="2026-09-06T20:00:00Z")
    _git(repo, "checkout", "-b", "develop")
    _commit(repo, "dev.py", "d\n" * 7, date="2026-09-06T21:00:00Z")

    act = collect_activity(
        repo,
        author_emails=[EMAIL],
        since_iso="2025-01-01 00:00:00 +0000",
        tz=TZ,
        path_filter=PathFilter.for_repo(repo, []),
    )

    assert act.commit_count == 2  # commits on develop count too (go-ce-v3 lesson)
    assert act.language_weights == {"Python": 12}


def test_activity_roundtrip_and_fingerprint(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, "a.py", "x" * 3, date="2026-09-06T20:00:00Z")
    act = collect_activity(
        repo,
        author_emails=[EMAIL],
        since_iso="2025-01-01 00:00:00 +0000",
        tz=TZ,
        path_filter=PathFilter.for_repo(repo, []),
    )
    restored = activity_from_dict(activity_to_dict(act))
    assert restored.commits_by_day == act.commits_by_day
    assert restored.language_weights == act.language_weights
    assert restored.commit_count == act.commit_count
    assert refs_fingerprint(repo)  # stable non-empty hash


class TestCloneGate:
    """issue #8 修订：PROFILE_ALLOW_CLONES 门禁——本地默认拒绝克隆并打印提示。"""

    def test_default_refuses_with_hint(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.delenv("PROFILE_ALLOW_CLONES", raising=False)
        with pytest.raises(GitError, match="PROFILE_ALLOW_CLONES"):
            clone_or_refresh(
                "https://github.com/example/repo.git",
                tmp_path / "repo",
                token=None,
                since_iso="2025-01-01 00:00:00 +0000",
            )
        assert not (tmp_path / "repo").exists()  # 拒绝时零磁盘残留

    def test_env_var_allows_local_clone(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setenv("PROFILE_ALLOW_CLONES", "1")
        src = tmp_path / "src.git"
        subprocess.run(["git", "init", "--bare", "-q", str(src)], check=True, capture_output=True)
        dest = tmp_path / "dest"
        clone_or_refresh(str(src), dest, token=None, since_iso="2025-01-01 00:00:00 +0000")
        assert (dest / ".git").exists()  # 放行后正常走克隆回退链
