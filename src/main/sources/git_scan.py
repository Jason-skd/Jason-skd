"""Channel 2: shallow clones + ``git log`` mining.

Per repo: ``clone --shallow-since=<1y> --no-single-branch`` (or a fetch
refresh when cached), then a single ``git log --all --numstat`` filtered by
author emails yields per-day commit counts and per-file churn. Merge
commits emit no numstat by default, which avoids double counting.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from .language_scan import PathFilter, language_for

_BRACE_RE = re.compile(r"\{([^{}]*) => ([^{}]*)\}")


class GitError(RuntimeError):
    """git failed; messages are scrubbed so tokens never leak."""


@dataclass
class RepoActivity:
    """Commit-day counts + commit-weighted language churn for one repo."""

    commits_by_day: dict[str, int] = field(default_factory=dict)
    language_weights: dict[str, int] = field(default_factory=dict)
    last_commit_ts: int | None = None
    commit_count: int = 0


def _scrub(text: str, *, token: str | None, url: str | None) -> str:
    """Mask credentials: collapse the authed URL, then mask the raw token."""
    if url:
        text = text.replace(_authed_url(url, token), url)
    if token:
        text = text.replace(token, "***")
    return text


def _git(
    *args: str,
    repo_dir: Path | None = None,
    token: str | None = None,
    url: str | None = None,
    timeout: int = 600,
) -> str:
    cmd = ["git", "-c", "credential.helper=", *args]
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="echo", GIT_CONFIG_NOSYSTEM="1")
    try:
        proc = subprocess.run(
            cmd, cwd=repo_dir, env=env, capture_output=True, text=True, timeout=timeout, check=False
        )
    except subprocess.TimeoutExpired as exc:
        shown = _scrub(" ".join(args[:3]), token=token, url=url)
        msg = f"git {shown}... timed out after {timeout}s"
        raise GitError(msg) from exc
    except subprocess.SubprocessError as exc:
        raise GitError(f"git subprocess error: {type(exc).__name__}") from exc
    if proc.returncode != 0:
        err = _scrub((proc.stderr or proc.stdout or "").strip()[-400:], token=token, url=url)
        shown = _scrub(" ".join(args[:3]), token=token, url=url)
        msg = f"git {shown}... failed: {err}"
        raise GitError(msg)
    return proc.stdout


def _authed_url(url: str, token: str | None) -> str:
    if not token:
        return url
    return url.replace("https://github.com", f"https://x-access-token:{token}@github.com")


def clone_or_refresh(url: str, dest: Path, *, token: str | None, since_iso: str) -> None:
    """Clone shallow-since 1y with all branches, or refresh an existing clone.

    Repositories with zero commits in the window reject ``--shallow-since``,
    so clone falls back to ``--depth=200`` then a full clone.
    """
    fetch_url = _authed_url(url, token)
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            _git(
                "clone",
                f"--shallow-since={since_iso}",
                "--no-single-branch",
                "--quiet",
                fetch_url,
                str(dest),
                token=token,
                url=url,
            )
        except GitError:
            shutil.rmtree(dest, ignore_errors=True)
            try:
                _git(
                    "clone",
                    "--depth=200",
                    "--no-single-branch",
                    "--quiet",
                    fetch_url,
                    str(dest),
                    token=token,
                    url=url,
                )
            except GitError:
                shutil.rmtree(dest, ignore_errors=True)
                _git("clone", "--quiet", fetch_url, str(dest), token=token, url=url)
    else:
        try:
            _git(
                "fetch",
                f"--shallow-since={since_iso}",
                "--no-tags",
                "--prune",
                "--quiet",
                fetch_url,
                "+refs/heads/*:refs/remotes/origin/*",
                repo_dir=dest,
                token=token,
                url=url,
            )
        except GitError:
            _git(
                "fetch",
                "--no-tags",
                "--prune",
                "--quiet",
                fetch_url,
                "+refs/heads/*:refs/remotes/origin/*",
                repo_dir=dest,
                token=token,
                url=url,
            )


def refs_fingerprint(repo_dir: Path, *, token: str | None = None) -> str:
    """Stable hash of remote-tracking refs; changes when any branch moves."""
    out = _git(
        "for-each-ref",
        "refs/remotes/origin",
        "--format=%(refname) %(objectname)",
        repo_dir=repo_dir,
        token=token,
    )
    return hashlib.sha256(out.encode()).hexdigest()


def _clean_path(path: str) -> str:
    """Normalise a numstat path: strip quoting and rename notation."""
    if path.startswith('"') and path.endswith('"'):
        path = path[1:-1].encode("utf-8", "backslashreplace").decode("unicode_escape")
    if "{" in path and "}" in path:
        path = _BRACE_RE.sub(lambda m: m.group(2), path)
    if " => " in path:
        path = path.rsplit(" => ", 1)[-1]
    return path.strip()


def collect_activity(
    repo_dir: Path,
    *,
    author_emails: list[str],
    since_iso: str,
    tz: ZoneInfo,
    path_filter: PathFilter,
) -> RepoActivity:
    """One ``git log`` pass -> day buckets + language churn (user-touched files only)."""
    args = ["log", "--all", f"--since={since_iso}", "--numstat", "--format=%x00%at"]
    for email in author_emails:
        args.append(f"--author={email}")
    out = _git(*args, repo_dir=repo_dir)
    act = RepoActivity()
    for line in out.splitlines():
        if not line:
            continue
        if line.startswith("\x00"):
            ts = int(line[1:])
            day = datetime.fromtimestamp(ts, tz=tz).strftime("%Y-%m-%d")
            act.commits_by_day[day] = act.commits_by_day.get(day, 0) + 1
            act.commit_count += 1
            act.last_commit_ts = ts if act.last_commit_ts is None else max(act.last_commit_ts, ts)
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        added_s, deleted_s, raw_path = parts
        if added_s == "-" or deleted_s == "-":
            continue  # binary file
        path = _clean_path(raw_path)
        if not path or path_filter.excluded(path):
            continue
        lang = language_for(path)
        if lang is None:
            continue
        weight = int(added_s) + int(deleted_s)
        act.language_weights[lang] = act.language_weights.get(lang, 0) + weight
    return act


def activity_to_dict(act: RepoActivity) -> dict[str, object]:
    return {
        "commits_by_day": act.commits_by_day,
        "language_weights": act.language_weights,
        "last_commit_ts": act.last_commit_ts,
        "commit_count": act.commit_count,
    }


def activity_from_dict(data: dict[str, object]) -> RepoActivity:
    return RepoActivity(
        commits_by_day=dict(data.get("commits_by_day") or {}),  # type: ignore[arg-type]
        language_weights=dict(data.get("language_weights") or {}),  # type: ignore[arg-type]
        last_commit_ts=data.get("last_commit_ts"),  # type: ignore[arg-type]
        commit_count=int(data.get("commit_count") or 0),
    )
