"""profile.yaml 加载与校验（契约 issue #1）。"""

from pathlib import Path
from typing import Any

import yaml

KNOWN_SECTIONS: tuple[str, ...] = (
    "banner",
    "typing",
    "stats",
    "languages",
    "org_card",
    "recent_project",
)
TOGGLEABLE_SECTIONS: frozenset[str] = frozenset({"org_card", "recent_project"})
REQUIRED_TOP_LEVEL_KEYS: tuple[str, ...] = ("timezone", "theme", "sections")


class ConfigError(Exception):
    """profile.yaml 不符合契约 schema。"""


def load_profile(path: Path) -> dict[str, Any]:
    """读取并规范化 profile.yaml；违反契约抛 ConfigError。"""
    if not path.is_file():
        raise ConfigError(f"profile config not found: {path}")
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ConfigError("profile.yaml 顶层必须是映射（mapping）")
    for key in REQUIRED_TOP_LEVEL_KEYS:
        if key not in raw:
            raise ConfigError(f"profile.yaml 缺少必需键: {key}")
    sections = raw["sections"]
    if not isinstance(sections, list) or not sections:
        raise ConfigError("sections 必须是非空列表")
    unknown = [s for s in sections if s not in KNOWN_SECTIONS]
    if unknown:
        raise ConfigError(f"未知组件 section: {unknown}（合法值: {list(KNOWN_SECTIONS)}）")
    if len(set(sections)) != len(sections):
        raise ConfigError("sections 存在重复项")
    theme = raw.get("theme")
    if theme is None:
        theme = raw["theme"] = {}
    if not isinstance(theme, dict):
        raise ConfigError("theme 必须是映射")
    # 靛夜青（Tokyo Night 调性）方向已定；精确色值由组件层定稿后回填 issue #1
    theme.setdefault("accent", "7aa2f7")
    for name in TOGGLEABLE_SECTIONS:
        section = raw.get(name)
        if section is None:
            section = raw[name] = {}
        if not isinstance(section, dict):
            raise ConfigError(f"{name} 配置必须是映射")
        section.setdefault("enabled", True)
    raw.setdefault("excludes", {"repos": [], "languages": [], "paths": []})
    return raw


def enabled_sections(profile: dict[str, Any]) -> list[str]:
    """按 profile.yaml 顺序返回启用的 section 名。"""
    return [
        name
        for name in profile["sections"]
        if name not in TOGGLEABLE_SECTIONS or bool(profile.get(name, {}).get("enabled", True))
    ]


def section_config(profile: dict[str, Any], name: str) -> dict[str, Any]:
    """组件收到：共享 theme/timezone/excludes + 自身配置切片。"""
    shared = {
        "theme": profile["theme"],
        "timezone": profile["timezone"],
        "excludes": profile.get("excludes", {}),
    }
    return {**shared, **(profile.get(name) or {})}
