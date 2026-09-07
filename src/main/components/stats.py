"""stats 组件：三枚数据徽章 + 可见口径脚注。

锁定口径（issue #1）：21 stars / 976 contributions / 149 active days，
脚注「含 320 条私有贡献」必须可见（不藏在 HTML 注释里）。
数字全部来自 data/stats.json（数据源层 issue #2 产出），组件不自带数字。
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

from main.components._theme import resolve_theme

_SHIELDS = "https://img.shields.io/badge"


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染 shields.io 徽章行 + 口径脚注。"""
    theme = resolve_theme(config)
    stars = int(data["stars"])
    contributions = int(data["contributions"])
    active_days = int(data["activeDays"])
    window = int(data.get("windowDays", 365))
    private = int(data.get("privateContributions", 0))
    breakdown = data.get("breakdown") or {}
    header = str(config.get("header") or f"📊 过去 {window} 天")

    color = theme["accent"]
    badges = (
        _badge("Stars", stars, color)
        + _badge("Contributions", contributions, color)
        + _badge("Active days", active_days, color)
    )

    segments = [f"近 {window} 天 · 含 {private} 条私有贡献"]
    public_parts = [
        f"{int(breakdown.get('commits', 0))} commits",
        f"{int(breakdown.get('issues', 0))} issues",
        f"{int(breakdown.get('pullRequests', 0))} PRs",
        f"{int(breakdown.get('reviews', 0))} reviews",
    ]
    segments.append("公开拆分：" + " · ".join(public_parts))
    if data.get("degraded"):
        segments.append("⚠️ 降级口径（无 PAT，仅公开数据）")

    return "\n".join(
        [
            f'<h3 align="left">{header}</h3>',
            "",
            "<p>",
            badges,
            "</p>",
            "",
            f'<p align="left"><sub>{" ｜ ".join(segments)}</sub></p>',
        ]
    )


def _badge(label: str, value: int, color: str) -> str:
    url = (
        f"{_SHIELDS}/{quote(label.lower(), safe='')}-{value}-{color}?style=flat-square"
    )
    return f'  <img alt="{label}" src="{url}" />'
