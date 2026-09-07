"""sources/ orchestration: config + channels -> the four data payloads.

Output shapes are frozen by issue #1 and materialised by the integrator's
fixtures (origin/feat/dp-pipeline @ d9e094d): stats/org/recent are flat
camelCase objects, languages is a bare ``[{lang, weight, pct}]`` array.

Two consumers:
- ``run(...)``  writes ``data/*.json`` (cli detects the directory, option B);
- ``collect(...)`` returns the four payloads as dicts (option A).

Degradation policy (issue #2): never crash on missing token, network failure
or a broken repo; unavailable numbers become ``null`` with ``degraded`` set.
"""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from .config import ProfileConfig, load_config
from .emit import write_json
from .git_scan import (
    GitError,
    activity_from_dict,
    activity_to_dict,
    clone_or_refresh,
    collect_activity,
    refs_fingerprint,
)
from .github_graphql import AccountData, RepoMeta, empty_account, fetch_account
from .http import GitHubClient, resolve_token
from .language_scan import PathFilter, aggregate_languages
from .org_activity import fetch_org, fetch_repo_meta
from .recent import pick_recent


def _repo_excluded(repo: str, patterns: list[str]) -> bool:
    """Match exclusions against ``owner/name`` or the bare name."""
    bare = repo.rsplit("/", 1)[-1].lower()
    return any(p.lower() in (repo.lower(), bare) for p in patterns)


def _dominant_language(weights: dict[str, int]) -> str | None:
    if not weights:
        return None
    return max(sorted(weights), key=lambda lang: weights[lang])


def _stale_cache_usable(dest: Path, cached: dict[str, Any]) -> bool:
    """True when the local clone's refs still match the last scan (data is current)."""
    try:
        return refs_fingerprint(dest) == cached.get("fingerprint")
    except GitError:
        return False


def _save_scan_cache(cache_file: Path, scan_cache: dict[str, dict[str, Any]]) -> None:
    """Best-effort write-through so a mid-run crash keeps finished repos."""
    try:
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(scan_cache, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def _channel2_repo_set(cfg: ProfileConfig, account: AccountData, notes: list[str]) -> list[str]:
    own = [r.name_with_owner for r in account.repos]
    if not own:
        notes.append("own repo list unavailable: language scan limited to org/external repos")
    externals = account.external_repos if cfg.include_external else []
    ordered = list(dict.fromkeys(own + cfg.org.repos + externals))
    return [r for r in ordered if not _repo_excluded(r, cfg.excludes.repos)]


def _recent_meta(
    repo: str,
    metas: dict[str, RepoMeta],
    client: GitHubClient,
    *,
    allow_network: bool,
) -> dict[str, Any]:
    meta = metas.get(repo)
    if meta is not None:
        return {
            "url": f"https://github.com/{repo}",
            "desc": meta.description,
            "lang": meta.primary_language,
        }
    desc: str | None = None
    lang: str | None = None
    if allow_network:
        desc, lang = fetch_repo_meta(client, repo)
    return {"url": f"https://github.com/{repo}", "desc": desc, "lang": lang}


def _gather(
    config_path: str | Path,
    token: str | None,
    *,
    no_network: bool,
    from_iso: str | None,
    to_iso: str | None,
    cache_dir: str | Path | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Fetch everything; returns (payloads, run summary)."""
    cfg = load_config(config_path)
    token = resolve_token(token)
    tz = ZoneInfo(cfg.timezone)
    client = GitHubClient(token)

    to_dt = datetime.fromisoformat(to_iso) if to_iso else datetime.now(UTC)
    if to_dt.tzinfo is None:
        to_dt = to_dt.replace(tzinfo=UTC)
    from_dt = to_dt - timedelta(days=cfg.window_days)
    from_api = from_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    to_api = to_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    from_git = from_dt.strftime("%Y-%m-%d %H:%M:%S +0000")
    generated_at = datetime.now(tz).isoformat(timespec="seconds")

    # ---- Channel 1 -------------------------------------------------------
    notes: list[str] = []
    if no_network:
        account = empty_account(cfg.login, ["--no-network: channel 1 skipped"])
    else:
        try:
            account = fetch_account(client, cfg.login, from_iso=from_api, to_iso=to_api)
        except Exception as exc:
            account = empty_account(cfg.login, [f"channel 1 failed: {exc}"])
    notes.extend(account.notes)

    # ---- Org branding ----------------------------------------------------
    branding = fetch_org(client, cfg.org, allow_network=not no_network)

    # ---- Channel 2 -------------------------------------------------------
    ch2_notes: list[str] = []
    repos = _channel2_repo_set(cfg, account, ch2_notes)
    cache_root = Path(cache_dir) if cache_dir else Path(".cache")
    clone_dir = cache_root / "repos"
    cache_file = cache_root / "scan_cache.json"
    scan_cache: dict[str, dict[str, Any]] = {}
    if cache_file.exists():
        try:
            scan_cache = dict(json.loads(cache_file.read_text(encoding="utf-8")))
        except OSError, ValueError:
            scan_cache = {}

    activities: dict[str, Any] = {}
    skipped: list[dict[str, str]] = []
    # filter fingerprint: cache entries must invalidate when scan inputs change
    filter_hash = hashlib.sha256(
        json.dumps(
            {"emails": cfg.author_emails, "paths": cfg.excludes.paths},
            ensure_ascii=False,
            sort_keys=True,
        ).encode()
    ).hexdigest()[:16]
    for repo in repos:
        url = f"https://github.com/{repo}.git"
        dest = clone_dir / repo.replace("/", "__")
        try:
            if no_network and not dest.exists():
                skipped.append({"repo": repo, "reason": "no-network and repo not cached"})
                continue
            try:
                clone_or_refresh(url, dest, token=token, since_iso=from_git)
            except GitError as exc:
                # network hiccup: degrade to the stale cache when refs are unchanged
                cached = scan_cache.get(repo)
                if dest.exists() and cached and _stale_cache_usable(dest, cached):
                    activities[repo] = activity_from_dict(cached["activity"])  # type: ignore[arg-type]
                    ch2_notes.append(f"{repo}: refresh failed ({exc}); using stale cache")
                    continue
                raise
            fingerprint = refs_fingerprint(dest)
            cached = scan_cache.get(repo)
            if (
                cached
                and cached.get("fingerprint") == fingerprint
                and cached.get("window_from") == from_api
                and cached.get("filter_hash") == filter_hash
            ):
                act = activity_from_dict(cached["activity"])  # type: ignore[arg-type]
            else:
                path_filter = PathFilter.for_repo(dest, cfg.excludes.paths)
                act = collect_activity(
                    dest,
                    author_emails=cfg.author_emails,
                    since_iso=from_git,
                    tz=tz,
                    path_filter=path_filter,
                )
                scan_cache[repo] = {
                    "fingerprint": fingerprint,
                    "window_from": from_api,
                    "filter_hash": filter_hash,
                    "activity": activity_to_dict(act),
                }
                _save_scan_cache(cache_file, scan_cache)  # crash-safe incremental progress
            activities[repo] = act
        except (GitError, OSError) as exc:
            skipped.append({"repo": repo, "reason": str(exc)})
    if skipped:
        ch2_notes.append(f"{len(skipped)} repo(s) skipped (see summary.reposSkipped)")
    try:
        cache_root.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(scan_cache, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass  # cache is best-effort

    # ---- languages --------------------------------------------------------
    languages = aggregate_languages(
        {r: a.language_weights for r, a in activities.items()},
        exclude_languages=cfg.excludes.languages,
        top=cfg.languages_top,
    )

    # ---- recent -----------------------------------------------------------
    own_and_org = {r.name_with_owner for r in account.repos} | set(cfg.org.repos)
    candidates = {r for r in own_and_org if not _repo_excluded(r, cfg.excludes.repos)}
    if not cfg.exclude_external_recent:
        externals = set(account.external_repos) if cfg.include_external else set()
        candidates |= {r for r in externals if not _repo_excluded(r, cfg.excludes.repos)}
    today = to_dt.astimezone(tz).date() if to_iso else None
    pick = pick_recent(activities, candidates=candidates, tz=tz, today=today)
    if pick is not None:
        meta = _recent_meta(
            pick.repo,
            {r.name_with_owner: r for r in account.repos},
            client,
            allow_network=not no_network,
        )
        if meta["lang"] is None:
            meta["lang"] = _dominant_language(activities[pick.repo].language_weights)
        recent_payload: dict[str, Any] = {
            "repo": pick.repo.rsplit("/", 1)[-1],
            "url": meta["url"],
            "desc": meta["desc"],
            "lang": meta["lang"],
            "commits": pick.commits,
            "date": pick.day,
            "external": pick.repo not in own_and_org,
        }
    else:
        recent_payload = {
            "repo": None,
            "url": None,
            "desc": None,
            "lang": None,
            "commits": None,
            "date": None,
            "external": None,
        }
        ch2_notes.append("no commits found in lookback window")

    # ---- payloads (frozen shapes, see module docstring) --------------------
    stats_degraded = account.contributions_total is None or not account.self_view
    stats_payload = {
        "stars": account.stars(private_too=True) if account.repos else None,
        "contributions": account.contributions_total,
        "activeDays": account.active_days,
        "windowDays": cfg.window_days,
        "breakdown": {
            "commits": account.commits,
            "issues": account.issues,
            "pullRequests": account.pull_requests,
            "reviews": account.reviews,
            "repositories": account.new_repositories,
        },
        "publicContributions": account.public_sum,
        "privateContributions": (
            account.restricted if account.contributions_total is not None else None
        ),
        "degraded": stats_degraded,
        "generatedAt": generated_at,
    }
    payloads: dict[str, Any] = {
        "stats": stats_payload,
        "org": {"name": branding.name, "logo": branding.logo, "url": branding.url},
        "languages": languages,
        "recent": recent_payload,
    }

    summary: dict[str, Any] = {
        "window": {"from": from_api, "to": to_api},
        "degraded": stats_degraded or bool(skipped) or pick is None or branding.source == "partial",
        "notes": notes + ch2_notes + branding.notes,
        "reposScanned": len(activities),
        "reposSkipped": skipped,
        "starsTotal": stats_payload["stars"],
        "contributionsTotal": stats_payload["contributions"],
        "activeDays": stats_payload["activeDays"],
        "languagesTop3": [entry["lang"] for entry in languages[:3]],
        "recentRepo": recent_payload["repo"],
    }
    return payloads, summary


def collect(
    config_path: str | Path = "profile.yaml",
    token: str | None = None,
    *,
    with_summary: bool = False,
) -> dict[str, Any] | tuple[dict[str, Any], dict[str, Any]]:
    """Option A consumer API: the four payloads, isomorphic to data/*.json.

    ``with_summary=True`` additionally returns the run summary so callers
    (cli) can surface channel-2 degradation (skipped repos) instead of
    silently producing partial data.
    """
    payloads, summary = _gather(
        config_path, token, no_network=False, from_iso=None, to_iso=None, cache_dir=None
    )
    if with_summary:
        return payloads, summary
    return payloads


def run(
    config_path: str | Path = "profile.yaml",
    out_dir: str | Path = "data",
    token: str | None = None,
    *,
    no_network: bool = False,
    from_iso: str | None = None,
    to_iso: str | None = None,
    cache_dir: str | Path | None = None,
) -> dict[str, Any]:
    """Fetch everything and write the four data files. Returns a run summary."""
    payloads, summary = _gather(
        config_path,
        token,
        no_network=no_network,
        from_iso=from_iso,
        to_iso=to_iso,
        cache_dir=cache_dir,
    )
    out = Path(out_dir)
    files = {
        "stats": write_json(out, "stats.json", payloads["stats"]),
        "org": write_json(out, "org.json", payloads["org"]),
        "languages": write_json(out, "languages.json", payloads["languages"]),
        "recent": write_json(out, "recent.json", payloads["recent"]),
    }
    summary["files"] = {k: str(v) for k, v in files.items()}
    return summary
