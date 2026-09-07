"""Regression tests: token scrubbing in git errors + stale-cache fallback (issue #2)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from main.sources import pipeline as pipeline_mod
from main.sources.git_scan import GitError, _git, refs_fingerprint
from main.sources.github_graphql import empty_account
from main.sources.org_activity import OrgBranding
from main.sources.pipeline import run


def test_git_error_never_leaks_token(tmp_path: Path) -> None:
    fake_token = "FAKE123TOKEN"
    authed = f"https://x-access-token:{fake_token}@127.0.0.1:1/x/y.git"
    with pytest.raises(GitError) as exc_info:
        _git(
            "clone",
            "--quiet",
            authed,
            str(tmp_path / "dest"),
            token=fake_token,
            url="https://127.0.0.1:1/x/y.git",
            timeout=10,
        )
    msg = str(exc_info.value)
    assert fake_token not in msg
    assert "x-access-token:***@" in msg  # authed url collapsed, token masked


def _seed_repo_with_remote_ref(base: Path, name: str) -> Path:
    """A tiny repo with one commit and a remote-tracking ref for fingerprints."""
    import os
    import subprocess

    repo = base / name
    repo.mkdir(parents=True)
    env = dict(
        os.environ,
        GIT_AUTHOR_EMAIL="wintor76111@gmail.com",
        GIT_COMMITTER_EMAIL="wintor76111@gmail.com",
    )
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True, capture_output=True)
    (repo / "a.py").write_text("x\n" * 3, encoding="utf-8")
    subprocess.run(["git", "add", "a.py"], cwd=repo, check=True, capture_output=True, env=env)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=T",
            "-c",
            "user.email=wintor76111@gmail.com",
            "commit",
            "-q",
            "-m",
            "c",
        ],
        cwd=repo,
        check=True,
        capture_output=True,
        env=env,
    )
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()
    subprocess.run(
        ["git", "update-ref", "refs/remotes/origin/main", sha],
        cwd=repo,
        check=True,
        capture_output=True,
    )
    return repo


def test_network_failure_falls_back_to_stale_cache(tmp_path, monkeypatch) -> None:
    base = tmp_path / "prep"
    repo = _seed_repo_with_remote_ref(base, "SCNUAutoPtr__go-ce-v3")
    fingerprint = refs_fingerprint(repo)

    cache_root = tmp_path / "cache"
    clone_dir = cache_root / "repos"
    clone_dir.mkdir(parents=True)
    # move the seeded repo into the place the pipeline expects
    seeded = clone_dir / "SCNUAutoPtr__go-ce-v3"
    repo.rename(seeded)
    (cache_root / "scan_cache.json").write_text(
        json.dumps(
            {
                "SCNUAutoPtr/go-ce-v3": {
                    "fingerprint": fingerprint,
                    "window_from": "1999-01-01T00:00:00Z",  # stale window, still usable
                    "activity": {
                        "commits_by_day": {"2026-09-06": 2},
                        "language_weights": {"Go": 42},
                        "last_commit_ts": 1773000000,
                        "commit_count": 2,
                    },
                }
            }
        ),
        encoding="utf-8",
    )

    def broken_clone_or_refresh(url, dest, *, token, since_iso):
        msg = "simulated network failure"
        raise GitError(msg)

    monkeypatch.setattr(pipeline_mod, "clone_or_refresh", broken_clone_or_refresh)
    monkeypatch.setattr(
        pipeline_mod,
        "fetch_account",
        lambda client, login, *, from_iso, to_iso: empty_account(login, ["unit test"]),
    )
    monkeypatch.setattr(
        pipeline_mod,
        "fetch_org",
        lambda client, org, *, allow_network: OrgBranding(org.login, "N", "L", "U", "config", []),
    )

    cfg = tmp_path / "profile.yaml"
    cfg.write_text("timezone: Asia/Shanghai\n", encoding="utf-8")
    out = tmp_path / "data"
    summary = run(cfg, out, token=None, cache_dir=cache_root)

    assert summary["reposSkipped"] == []  # stale cache saved the repo
    languages = json.loads((out / "languages.json").read_text(encoding="utf-8"))
    assert languages == [{"lang": "Go", "weight": 42, "pct": 100.0}]
    recent = json.loads((out / "recent.json").read_text(encoding="utf-8"))
    assert recent["repo"] == "go-ce-v3"  # from stale activity
    assert any("stale cache" in note for note in summary["notes"])
