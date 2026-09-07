"""profile.yaml loading for the data source layer.

Schema authority: issue #1 + the integrator's concretised profile.yaml
(origin/feat/dp-pipeline @ d9e094d). Only keys consumed by sources/ are
modelled here; unknown keys (sections, typing, theme, ...) belong to the
component/pipeline layers and are ignored tolerantly.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

DEFAULT_LOGIN = "Jason-skd"
DEFAULT_TIMEZONE = "Asia/Shanghai"
DEFAULT_WINDOW_DAYS = 365
DEFAULT_AUTHOR_EMAILS = ["wintor76111@gmail.com"]
DEFAULT_ORG_LOGIN = "SCNUAutoPtr"
DEFAULT_ORG_REPOS = ["SCNUAutoPtr/go-ce-v3"]
DEFAULT_EXCLUDE_PATHS = [
    "**/vendor/**",
    "**/vendors/**",
    "**/third_party/**",
    "**/thirdparty/**",
    "**/third-party/**",
    "**/extern/**",
    "**/external/**",
    "**/deps/**",
]
DEFAULT_LANGUAGES_TOP = 12


@dataclass
class OrgConfig:
    """Org card branding + org repos to scan."""

    login: str = DEFAULT_ORG_LOGIN
    repos: list[str] = field(default_factory=lambda: list(DEFAULT_ORG_REPOS))
    name: str | None = None
    logo: str | None = None
    url: str | None = None


@dataclass
class ExcludeConfig:
    """Exclusion lists: repos (owner/name or bare name), languages, path globs."""

    repos: list[str] = field(default_factory=list)
    languages: list[str] = field(default_factory=list)
    paths: list[str] = field(default_factory=lambda: list(DEFAULT_EXCLUDE_PATHS))


@dataclass
class ProfileConfig:
    """Everything sources/ needs from profile.yaml."""

    login: str = DEFAULT_LOGIN
    timezone: str = DEFAULT_TIMEZONE
    window_days: int = DEFAULT_WINDOW_DAYS
    author_emails: list[str] = field(default_factory=lambda: list(DEFAULT_AUTHOR_EMAILS))
    org: OrgConfig = field(default_factory=OrgConfig)
    excludes: ExcludeConfig = field(default_factory=ExcludeConfig)
    include_external: bool = True
    languages_top: int = DEFAULT_LANGUAGES_TOP
    exclude_external_recent: bool = True


def _as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    return [str(v) for v in value]


def _pick_list(raw: dict[str, Any], key: str, default: list[str]) -> list[str]:
    """Explicit empty lists are respected; defaults apply only when the key is absent."""
    if key in raw:
        return _as_list(raw[key])
    return list(default)


def _build(raw: dict[str, Any]) -> ProfileConfig:
    org_raw = raw.get("org") or {}
    org = OrgConfig(
        login=str(org_raw.get("login") or DEFAULT_ORG_LOGIN),
        repos=_pick_list(org_raw, "repos", DEFAULT_ORG_REPOS),
        name=org_raw.get("name"),
        logo=org_raw.get("logo"),
        url=org_raw.get("url"),
    )
    # The frozen key is `excludes`; `exclude` stays accepted as a legacy alias.
    excl_raw = raw.get("excludes")
    if excl_raw is None:
        excl_raw = raw.get("exclude") or {}
    excludes = ExcludeConfig(
        repos=_pick_list(excl_raw, "repos", []),
        languages=_pick_list(excl_raw, "languages", []),
        paths=_pick_list(excl_raw, "paths", DEFAULT_EXCLUDE_PATHS),
    )
    recent_raw = raw.get("recent_project") or {}
    lang_raw = raw.get("languages_card") or {}
    return ProfileConfig(
        login=str(raw.get("login") or DEFAULT_LOGIN),
        timezone=str(raw.get("timezone") or DEFAULT_TIMEZONE),
        window_days=int(raw.get("window_days") or DEFAULT_WINDOW_DAYS),
        author_emails=_pick_list(raw, "author_emails", DEFAULT_AUTHOR_EMAILS),
        org=org,
        excludes=excludes,
        include_external=bool(raw.get("include_external", True)),
        languages_top=int(lang_raw.get("top") or DEFAULT_LANGUAGES_TOP),
        exclude_external_recent=bool(recent_raw.get("exclude_external", True)),
    )


def load_config(path: str | Path) -> ProfileConfig:
    """Load profile.yaml; missing file -> defaults (marked scenario handled upstream)."""
    p = Path(path)
    if not p.exists():
        return ProfileConfig()
    raw = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    if not isinstance(raw, dict):
        msg = f"profile config must be a mapping: {p}"
        raise ValueError(msg)
    return _build(raw)
