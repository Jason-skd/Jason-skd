"""stats 组件：三枚数据徽章 + 精简口径脚注。

口径（issue #1 / v1.1）：stars / contributions / active days 来自
data/stats.json（数据源层 issue #2 产出），组件不自带数字；
脚注「近 N 天 · 含 X 条私有贡献」必须可见（不藏在 HTML 注释里），
公开拆分明细已按 v1.1 精简移除（用户如需可再恢复）。
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

from main.components._theme import resolve_theme

_SHIELDS = "https://img.shields.io/badge"


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染 shields.io 徽章行 + 口径脚注（v1.1：for-the-badge、居中、精简脚注）。"""
    theme = resolve_theme(config)
    stars = int(data["stars"])
    contributions = int(data["contributions"])
    active_days = int(data["activeDays"])
    window = int(data.get("windowDays", 365))
    private = int(data.get("privateContributions", 0))
    header = str(config.get("header") or f"📊 过去 {window} 天")

    color = theme["accent"]
    badges = (
        _badge("Stars", stars, color)
        + _badge("Contributions", contributions, color)
        + _badge("Active days", active_days, color)
    )

    segments = [f"近 {window} 天 · 含 {private} 条私有贡献"]
    if data.get("degraded"):
        segments.append("⚠️ 降级口径（无 PAT，仅公开数据）")

    return "\n".join(
        [
            f'<h3 align="center">{header}</h3>',
            "",
            '<p align="center">',
            badges,
            "</p>",
            "",
            f'<p align="center"><sub>{" ｜ ".join(segments)}</sub></p>',
        ]
    )


def _badge(label: str, value: int, color: str) -> str:
    url = f"{_SHIELDS}/{quote(label.lower(), safe='')}-{value}-{color}?style=for-the-badge"
    return f'  <img alt="{label}" src="{url}" />'
