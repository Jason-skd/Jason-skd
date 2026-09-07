"""Channel 1: account, contributions, stars and external repos via GraphQL.

One request per run in the common case (viewer query with the profile
owner's PAT). When the token does not belong to the profile owner (e.g. a
``GITHUB_TOKEN`` from Actions), a second ``user(login:)`` query provides the
public-only caliber and the result is marked degraded.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .http import GitHubClient

_FIELDS = """
      login
      repositories(first: 100, affiliations: OWNER, isFork: false) {
        nodes {
          name
          nameWithOwner
          description
          isPrivate
          stargazerCount
          primaryLanguage { name }
        }
      }
      contributionsCollection(from: $from, to: $to) {
        totalCommitContributions
        totalIssueContributions
        totalPullRequestContributions
        totalPullRequestReviewContributions
        totalRepositoryContributions
        restrictedContributionsCount
        contributionCalendar {
          totalContributions
          weeks { contributionDays { contributionCount } }
        }
        commitContributionsByRepository {
          repository {
            nameWithOwner
            isPrivate
            owner { login }
          }
        }
      }
"""

VIEWER_QUERY = f"""query ($from: DateTime!, $to: DateTime!) {{
  viewer {{ {_FIELDS} }}
}}"""

USER_QUERY = f"""query ($login: String!, $from: DateTime!, $to: DateTime!) {{
  user(login: $login) {{ {_FIELDS} }}
}}"""


@dataclass(frozen=True)
class RepoMeta:
    """A repository owned by the profile owner (forks excluded)."""

    name: str
    name_with_owner: str
    description: str | None
    is_private: bool
    stars: int
    primary_language: str | None


@dataclass
class AccountData:
    """Parsed Channel 1 result."""

    login: str
    self_view: bool
    repos: list[RepoMeta] = field(default_factory=list)
    contributions_total: int | None = None
    commits: int | None = None
    issues: int | None = None
    pull_requests: int | None = None
    reviews: int | None = None
    new_repositories: int | None = None
    restricted: int = 0
    active_days: int | None = None
    external_repos: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def public_sum(self) -> int | None:
        if None in (
            self.commits,
            self.issues,
            self.pull_requests,
            self.reviews,
            self.new_repositories,
        ):
            return None
        return (
            self.commits + self.issues + self.pull_requests + self.reviews + self.new_repositories
        )  # type: ignore[operator]

    def stars(self, *, private_too: bool) -> int:
        return sum(r.stars for r in self.repos if private_too or not r.is_private)


def _parse(node: dict[str, Any], *, self_view: bool, notes: list[str]) -> AccountData:
    repos = [
        RepoMeta(
            name=str(n["name"]),
            name_with_owner=str(n["nameWithOwner"]),
            description=n.get("description"),
            is_private=bool(n["isPrivate"]),
            stars=int(n["stargazerCount"]),
            primary_language=(n.get("primaryLanguage") or {}).get("name"),
        )
        for n in node["repositories"]["nodes"]
    ]
    cc = node["contributionsCollection"]
    active_days = sum(
        1
        for week in cc["contributionCalendar"]["weeks"]
        for day in week["contributionDays"]
        if day["contributionCount"] > 0
    )
    login = str(node["login"])
    external = sorted(
        {
            str(entry["repository"]["nameWithOwner"])
            for entry in cc.get("commitContributionsByRepository", [])
            if not entry["repository"]["isPrivate"]
            and str(entry["repository"]["owner"]["login"]).lower() != login.lower()
        }
    )
    return AccountData(
        login=login,
        self_view=self_view,
        repos=repos,
        contributions_total=int(cc["contributionCalendar"]["totalContributions"]),
        commits=int(cc["totalCommitContributions"]),
        issues=int(cc["totalIssueContributions"]),
        pull_requests=int(cc["totalPullRequestContributions"]),
        reviews=int(cc["totalPullRequestReviewContributions"]),
        new_repositories=int(cc["totalRepositoryContributions"]),
        restricted=int(cc["restrictedContributionsCount"]),
        active_days=active_days,
        external_repos=external,
        notes=notes,
    )


def empty_account(login: str, notes: list[str]) -> AccountData:
    """Degraded placeholder when Channel 1 cannot run at all."""
    return AccountData(login=login, self_view=False, notes=notes)


def fetch_account(client: GitHubClient, login: str, *, from_iso: str, to_iso: str) -> AccountData:
    """Fetch account stats; degrade to public caliber when the token is not the owner."""
    if not client.token:
        return empty_account(login, ["no token: GraphQL contributions unavailable (degraded)"])
    data = client.graphql(VIEWER_QUERY, {"from": from_iso, "to": to_iso})
    node = data.get("viewer") or {}
    notes: list[str] = []
    if str(node.get("login", "")).lower() != login.lower():
        data = client.graphql(USER_QUERY, {"login": login, "from": from_iso, "to": to_iso})
        node = data.get("user") or {}
        if not node:
            msg = f"user {login} not found"
            raise ValueError(msg)
        notes.append("token is not the profile owner: public-only caliber")
    return _parse(node, self_view=not notes, notes=notes)
