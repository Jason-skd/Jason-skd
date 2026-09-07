"""End-to-end offline test: run() with no network must still emit 4 contract-shaped jsons."""

from __future__ import annotations

import json
from pathlib import Path

from main.sources.pipeline import run


def test_run_offline_degrades_but_produces_files(tmp_path: Path) -> None:
    cfg = tmp_path / "profile.yaml"
    cfg.write_text(
        """
login: Jason-skd
timezone: Asia/Shanghai
window_days: 365
author_emails: [wintor76111@gmail.com]
org:
  login: SCNUAutoPtr
  repos: [SCNUAutoPtr/go-ce-v3]
""",
        encoding="utf-8",
    )
    out = tmp_path / "data"
    summary = run(
        cfg,
        out,
        token=None,
        no_network=True,
        from_iso="2025-09-07T12:00:00Z",
        to_iso="2026-09-07T12:00:00Z",
        cache_dir=tmp_path / "cache",
    )

    files = {p.name: json.loads(p.read_text(encoding="utf-8")) for p in out.glob("*.json")}
    assert set(files) == {"stats.json", "org.json", "languages.json", "recent.json"}

    stats = files["stats.json"]
    assert set(stats) == {
        "stars",
        "contributions",
        "activeDays",
        "windowDays",
        "breakdown",
        "publicContributions",
        "privateContributions",
        "degraded",
        "generatedAt",
    }
    assert stats["degraded"] is True
    assert stats["contributions"] is None
    assert stats["stars"] is None
    assert stats["breakdown"]["commits"] is None
    assert stats["windowDays"] == 365
    assert stats["generatedAt"].endswith("+08:00")  # profile timezone, contract format

    org = files["org.json"]
    assert set(org) == {"name", "logo", "url"}
    assert org["name"] is None  # no API + no overrides -> degraded nulls

    languages = files["languages.json"]
    assert isinstance(languages, list) and languages == []  # bare array per contract

    recent = files["recent.json"]
    assert set(recent) == {"repo", "url", "desc", "lang", "commits", "date", "external"}
    assert recent["repo"] is None

    assert summary["degraded"] is True
    assert summary["reposSkipped"] == [
        {"repo": "SCNUAutoPtr/go-ce-v3", "reason": "no-network and repo not cached"}
    ]


def test_run_offline_org_override_from_config(tmp_path: Path) -> None:
    cfg = tmp_path / "profile.yaml"
    cfg.write_text(
        """
org:
  login: SCNUAutoPtr
  name: AutoBits @ SCNUAutoPtr
  logo: https://example.com/logo.png
  url: https://github.com/SCNUAutoPtr
""",
        encoding="utf-8",
    )
    out = tmp_path / "data"
    run(cfg, out, token=None, no_network=True, cache_dir=tmp_path / "cache")

    org = json.loads((out / "org.json").read_text(encoding="utf-8"))
    assert org == {
        "name": "AutoBits @ SCNUAutoPtr",
        "logo": "https://example.com/logo.png",
        "url": "https://github.com/SCNUAutoPtr",
    }
