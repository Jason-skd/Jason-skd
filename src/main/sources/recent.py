"""Recent-project card algorithm (locked decision).

Walk back from *yesterday* (profile timezone) to the first day with user
commits; among repos with commits that day pick the argmax count, tie-break
by most recent last commit then name ascending. External repositories are
excluded from candidates by default.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import TYPE_CHECKING
from zoneinfo import ZoneInfo

if TYPE_CHECKING:
    from .git_scan import RepoActivity

MAX_LOOKBACK_DAYS = 60


@dataclass(frozen=True)
class RecentPick:
    repo: str
    commits: int
    day: str
    tier: str  # "yesterday"（回溯第 1 天命中）| "recently"（更早，v1.2 英文文案分档）


def pick_recent(
    activities: dict[str, RepoActivity],
    *,
    candidates: set[str] | None = None,
    tz: ZoneInfo,
    today: date | None = None,
    max_lookback: int = MAX_LOOKBACK_DAYS,
) -> RecentPick | None:
    """Return the winning (repo, commits, day) or None when nothing in range."""
    if today is None:
        today = datetime.now(tz).date()
    pool = {r: a for r, a in activities.items() if candidates is None or r in candidates}
    for offset in range(1, max_lookback + 1):
        day = (today - timedelta(days=offset)).isoformat()
        day_counts = {r: a.commits_by_day.get(day, 0) for r, a in pool.items()}
        day_counts = {r: c for r, c in day_counts.items() if c > 0}
        if not day_counts:
            continue
        best = min(
            day_counts,
            key=lambda r: (-day_counts[r], -(pool[r].last_commit_ts or 0), r),
        )
        tier = "yesterday" if offset == 1 else "recently"
        return RecentPick(repo=best, commits=day_counts[best], day=day, tier=tier)
    return None
