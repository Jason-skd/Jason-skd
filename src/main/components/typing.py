"""typing 组件：打字机效果（readme-typing-svg 官方 demolab 实例）。

文案即配置 —— 用户日常只改 profile.yaml 的 typing.lines；
宽度按字符宽度启发式自动估算（CJK 全角 ≈ 1em，其余 ≈ 0.65em），可显式覆盖。
"""

from __future__ import annotations

import math
import unicodedata
from typing import Any
from urllib.parse import quote_plus

from main.components._theme import resolve_theme

DEFAULT_INSTANCE = "https://readme-typing-svg.demolab.com/"
DEFAULT_FONT = "Fira Code"
DEFAULT_SIZE = 22
_ATTRIBUTION_URL = "https://git.io/typing-svg"


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染打字机 SVG 直链；data 未使用（无数据组件）。"""
    theme = resolve_theme(config)
    lines = [str(line) for line in config.get("lines") or []]
    if not lines:
        raise ValueError("typing.lines 不能为空（日常编辑点：profile.yaml）")
    if any(not line.strip() for line in lines):
        raise ValueError("typing.lines 含空白行")

    font = str(config.get("font", DEFAULT_FONT))
    size = int(config.get("size", DEFAULT_SIZE))
    if size <= 0:
        raise ValueError(f"typing.size 必须为正整数，得到 {size}")
    width = int(config.get("width") or _estimate_width(lines, size))
    height = int(config.get("height") or size * 2 + 18)
    duration = int(config.get("duration", 4000))
    pause = int(config.get("pause", 800))

    query = "&".join(
        [
            f"lines={';'.join(quote_plus(line) for line in lines)}",
            f"font={quote_plus(font)}",
            f"size={size}",
            f"width={width}",
            f"height={height}",
            f"color={theme['accent']}",
            "center=true",
            "vCenter=true",
            f"duration={duration}",
            f"pause={pause}",
        ]
    )
    url = f"{DEFAULT_INSTANCE}?{query}"
    return (
        '<p align="center">\n'
        f'  <a href="{_ATTRIBUTION_URL}">\n'
        f'    <img src="{url}" alt="Typing SVG" />\n'
        "  </a>\n"
        "</p>"
    )


def _estimate_width(lines: list[str], size: int) -> int:
    """按最长行的字符单位宽估算 SVG 宽度，向上取整到 10px。"""

    def units(text: str) -> float:
        return sum(
            1.0 if unicodedata.east_asian_width(ch) in "WF" else 0.65 for ch in text
        )

    longest = max(units(line) for line in lines)
    return int(math.ceil((longest * size + 60) / 10.0) * 10)
