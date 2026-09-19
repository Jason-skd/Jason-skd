"""config.load_profile 契约校验测试。"""

from pathlib import Path
from typing import Any

import pytest

from main.config import (
    ConfigError,
    enabled_sections,
    load_profile,
    section_config,
)

MINIMAL_YAML = """
timezone: Asia/Shanghai
theme: {}
sections: [banner, typing, stats]
"""


def _write(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "profile.yaml"
    path.write_text(text, encoding="utf-8")
    return path


def test_minimal_profile_gets_defaults(tmp_path: Path) -> None:
    profile = load_profile(_write(tmp_path, MINIMAL_YAML))
    assert profile["theme"]["accent"]  # 默认靛夜青占位
    assert profile["org_card"]["enabled"] is True
    assert profile["excludes"] == {"repos": [], "languages": [], "paths": []}


def test_missing_key_rejected(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="缺少必需键"):
        load_profile(_write(tmp_path, "timezone: Asia/Shanghai\n"))


def test_unknown_section_rejected(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="未知组件"):
        load_profile(_write(tmp_path, "timezone: t\ntheme: {}\nsections: [nope]\n"))


def test_duplicate_section_rejected(tmp_path: Path) -> None:
    text = "timezone: t\ntheme: {}\nsections: [banner, banner]\n"
    with pytest.raises(ConfigError, match="重复"):
        load_profile(_write(tmp_path, text))


def test_top_level_must_be_mapping(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="映射"):
        load_profile(_write(tmp_path, "- a\n- b\n"))


def test_missing_file_rejected(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="not found"):
        load_profile(tmp_path / "nope.yaml")


def test_enabled_sections_respects_toggle(tmp_path: Path) -> None:
    profile: dict[str, Any] = load_profile(_write(tmp_path, MINIMAL_YAML))
    assert enabled_sections(profile) == ["banner", "typing", "stats"]
    profile["sections"] = ["banner", "org_card", "recent_project"]
    profile["org_card"]["enabled"] = False
    assert enabled_sections(profile) == ["banner", "recent_project"]


def test_section_config_merges_shared_and_slice(tmp_path: Path) -> None:
    profile = load_profile(_write(tmp_path, MINIMAL_YAML))
    profile["typing"] = {"lines": ["hello"]}
    config = section_config(profile, "typing")
    assert config["lines"] == ["hello"]
    assert config["timezone"] == "Asia/Shanghai"
    assert config["theme"]["accent"]
    assert config["excludes"] == {"repos": [], "languages": [], "paths": []}
