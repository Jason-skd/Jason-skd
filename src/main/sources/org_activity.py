"""Org card branding (issue #1 contract: logo / name / url only).

The org card is pure branding (locked decision "option B"): no activity
numbers. Values come from ``GET /orgs/{login}`` with profile.yaml overrides
as fallback so the pipeline survives API/network failures.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .config import OrgConfig
from .http import GitHubClient


@dataclass
class OrgBranding:
    login: str
    name: str | None
    logo: str | None
    url: str | None
    source: str  # "api" | "config" | "mixed" | "partial"
    notes: list[str]


def fetch_org(client: GitHubClient, org: OrgConfig, *, allow_network: bool = True) -> OrgBranding:
    api: dict[str, Any] = {}
    notes: list[str] = []
    if allow_network:
        try:
            api = dict(client.rest(f"/orgs/{org.login}") or {})
        except Exception as exc:
            notes.append(f"org API unavailable: {exc}")
    overrides = {"name": org.name, "logo": org.logo, "url": org.url}
    used_override = any(v for v in overrides.values())
    if not api and not used_override:
        notes.append("org branding degraded: no API data and no overrides")
        return OrgBranding(org.login, None, None, None, "partial", notes)
    name = overrides["name"] or (api.get("name") or api.get("login"))
    logo = overrides["logo"] or api.get("avatar_url")
    url = overrides["url"] or api.get("html_url")
    source = "config" if not api else ("mixed" if used_override else "api")
    return OrgBranding(org.login, name, logo, url, source, notes)


def fetch_repo_meta(client: GitHubClient, name_with_owner: str) -> tuple[str | None, str | None]:
    """Best-effort (description, primary language) — org repos miss the viewer query."""
    try:
        data = dict(client.rest(f"/repos/{name_with_owner}") or {})
    except Exception:
        return None, None
    desc = data.get("description")
    lang = data.get("language")
    return (str(desc) if desc else None, str(lang) if lang else None)
