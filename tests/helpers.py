"""Shared test helpers: canned GitHub API payloads shaped like real responses."""

from __future__ import annotations

from typing import Any


def build_calendar(active_pattern: list[int]) -> dict[str, Any]:
    """One week of 7 days with the given contributionCount per day."""
    weeks = [{"contributionDays": [{"contributionCount": n} for n in active_pattern]}]
    return {"totalContributions": sum(active_pattern), "weeks": weeks}


def build_viewer_payload(
    *,
    login: str = "Jason-skd",
    repos: list[dict[str, Any]] | None = None,
    totals: dict[str, int] | None = None,
    calendar: list[int] | None = None,
    restricted: int = 0,
    externals: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    repos = (
        repos
        if repos is not None
        else [
            {
                "name": "dsh-session-fork",
                "nameWithOwner": "Jason-skd/dsh-session-fork",
                "description": "dsh plugin",
                "isPrivate": False,
                "stargazerCount": 7,
                "primaryLanguage": {"name": "TypeScript"},
            },
            {
                "name": "vassago",
                "nameWithOwner": "Jason-skd/vassago",
                "description": None,
                "isPrivate": True,
                "stargazerCount": 3,
                "primaryLanguage": {"name": "Python"},
            },
        ]
    )
    totals = (
        totals
        if totals is not None
        else {
            "totalCommitContributions": 538,
            "totalIssueContributions": 52,
            "totalPullRequestContributions": 41,
            "totalPullRequestReviewContributions": 15,
            "totalRepositoryContributions": 10,
        }
    )
    calendar = calendar if calendar is not None else [4, 0, 2, 0, 6, 0, 1]
    externals = (
        externals
        if externals is not None
        else [
            {
                "repository": {
                    "nameWithOwner": "awesome-dsh-plugin/awesome-dsh-plugin",
                    "isPrivate": False,
                    "owner": {"login": "awesome-dsh-plugin"},
                }
            }
        ]
    )
    return {
        "data": {
            "viewer": {
                "login": login,
                "repositories": {"nodes": repos},
                "contributionsCollection": {
                    **totals,
                    "restrictedContributionsCount": restricted,
                    "contributionCalendar": build_calendar(calendar),
                    "commitContributionsByRepository": externals,
                },
            }
        }
    }


def build_user_payload(login: str = "Jason-skd") -> dict[str, Any]:
    payload = build_viewer_payload(login=login, restricted=0)
    payload["data"]["user"] = payload["data"].pop("viewer")
    return payload


ORG_PAYLOAD: dict[str, Any] = {
    "login": "SCNUAutoPtr",
    "name": "AutoBits @ SCNUAutoPtr",
    "avatar_url": "https://avatars.githubusercontent.com/u/129657365?v=4",
    "html_url": "https://github.com/SCNUAutoPtr",
}
