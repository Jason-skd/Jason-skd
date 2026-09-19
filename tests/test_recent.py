"""Unit tests: recent-project day walk + tie-breaks."""

from __future__ import annotations

from datetime import date
from zoneinfo import ZoneInfo

from main.sources.git_scan import RepoActivity
from main.sources.recent import pick_recent

TZ = ZoneInfo("Asia/Shanghai")


def _act(
    days: dict[str, int], *, last_ts: int = 0, weights: dict[str, int] | None = None
) -> RepoActivity:
    return RepoActivity(commits_by_day=days, language_weights=weights or {}, last_commit_ts=last_ts)


def test_walk_starts_from_yesterday() -> None:
    today = date(2026, 9, 7)
    acts = {"Jason-skd/vassago": _act({"2026-09-06": 3})}
    pick = pick_recent(acts, candidates=None, tz=TZ, today=today)
    assert pick is not None
    assert (pick.repo, pick.commits, pick.day) == ("Jason-skd/vassago", 3, "2026-09-06")
    assert pick.tier == "yesterday"  # v1.2：回溯第 1 天命中


def test_today_is_ignored() -> None:
    today = date(2026, 9, 7)
    acts = {"a/b": _act({"2026-09-07": 9, "2026-09-05": 1})}
    pick = pick_recent(acts, candidates=None, tz=TZ, today=today)
    assert pick is not None
    assert pick.day == "2026-09-05"
    assert pick.tier == "recently"  # v1.2：更早日子命中


def test_argmax_then_last_commit_then_name() -> None:
    today = date(2026, 9, 7)
    acts = {
        "Jason-skd/alpha": _act({"2026-09-06": 2}, last_ts=1000),
        "Jason-skd/beta": _act({"2026-09-06": 5}, last_ts=1000),
        "Jason-skd/gamma": _act({"2026-09-06": 5}, last_ts=2000),
        "Jason-skd/delta": _act({"2026-09-06": 5}, last_ts=2000),
    }
    pick = pick_recent(acts, candidates=None, tz=TZ, today=today)
    assert pick is not None
    assert pick.repo == "Jason-skd/delta"  # 5 commits > 2; latest last_ts; name asc


def test_candidates_exclude_external() -> None:
    today = date(2026, 9, 7)
    acts = {
        "Jason-skd/own": _act({"2026-09-06": 1}),
        "ext/upstream": _act({"2026-09-06": 50}),
    }
    pick = pick_recent(acts, candidates={"Jason-skd/own"}, tz=TZ, today=today)
    assert pick is not None
    assert pick.repo == "Jason-skd/own"


def test_nothing_in_window_returns_none() -> None:
    today = date(2026, 9, 7)
    acts = {"a/b": _act({"2025-01-01": 3})}
    assert pick_recent(acts, candidates=None, tz=TZ, today=today, max_lookback=30) is None
