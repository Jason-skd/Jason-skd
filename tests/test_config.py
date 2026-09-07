"""Unit tests: profile.yaml loading (defaults, overrides, frozen-key semantics)."""

from __future__ import annotations

from pathlib import Path

import pytest

from main.sources.config import load_config

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_defaults_when_file_missing(tmp_path: Path) -> None:
    cfg = load_config(tmp_path / "nope.yaml")
    assert cfg.login == "Jason-skd"
    assert cfg.timezone == "Asia/Shanghai"
    assert cfg.window_days == 365
    assert cfg.author_emails == ["wintor76111@gmail.com"]
    assert cfg.org.repos == ["SCNUAutoPtr/go-ce-v3"]
    assert "**/vendor/**" in cfg.excludes.paths  # defaults when key absent
    assert cfg.include_external is True
    assert cfg.exclude_external_recent is True


def test_frozen_excludes_key_and_explicit_empty(tmp_path: Path) -> None:
    p = tmp_path / "profile.yaml"
    p.write_text(
        """
excludes:
  repos: []
  languages: []
  paths: []
""",
        encoding="utf-8",
    )
    cfg = load_config(p)
    # explicit empty lists are respected (integrator's frozen file has them)
    assert cfg.excludes.paths == []


def test_full_file_with_unknown_keys(tmp_path: Path) -> None:
    p = tmp_path / "profile.yaml"
    p.write_text(
        """
timezone: UTC
window_days: 180
author_emails:
  - a@example.com
  - b@example.com
sections: [banner, typing]        # component-layer key: ignored here
theme: {accent: "7aa2f7"}         # ignored here
org:
  login: MyOrg
  repos: [MyOrg/r1, MyOrg/r2]
  name: Override Name
excludes:
  repos: [Jason-skd/PECEI, PECEI2]
  languages: [HTML]
  paths: ["**/vend/**"]
include_external: false
languages_card: {top: 8}
recent_project:
  enabled: true
  exclude_external: false
""",
        encoding="utf-8",
    )
    cfg = load_config(p)
    assert cfg.timezone == "UTC"
    assert cfg.window_days == 180
    assert cfg.author_emails == ["a@example.com", "b@example.com"]
    assert cfg.org.login == "MyOrg"
    assert cfg.org.repos == ["MyOrg/r1", "MyOrg/r2"]
    assert cfg.org.name == "Override Name"
    assert cfg.excludes.repos == ["Jason-skd/PECEI", "PECEI2"]
    assert cfg.excludes.languages == ["HTML"]
    assert cfg.excludes.paths == ["**/vend/**"]
    assert cfg.include_external is False
    assert cfg.languages_top == 8
    assert cfg.exclude_external_recent is False


def test_legacy_exclude_alias_still_accepted(tmp_path: Path) -> None:
    p = tmp_path / "profile.yaml"
    p.write_text(
        """
exclude:
  languages: [CSS]
""",
        encoding="utf-8",
    )
    cfg = load_config(p)
    assert cfg.excludes.languages == ["CSS"]


@pytest.mark.skipif(
    not (REPO_ROOT / "profile.yaml").exists(), reason="local run profile not committed"
)
def test_local_profile_yaml_parses(tmp_path: Path) -> None:
    cfg = load_config(REPO_ROOT / "profile.yaml")
    assert cfg.timezone == "Asia/Shanghai"  # frozen key from integrator's file
    assert "wintor76111@gmail.com" in cfg.author_emails
    assert "SCNUAutoPtr/go-ce-v3" in cfg.org.repos
