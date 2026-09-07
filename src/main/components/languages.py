"""languages 组件：commit 加权语言统计（纯 devicon 图标行，v1.1）。

数据来自 data/languages.json（数据源层 issue #2 产出）：
``[{"lang": ..., "weight": ..., "pct": ...}, ...]``，已剔除 vendor 与
Markdown/JSON 类（excludes.languages，占比自动重归一）、含组织/外部仓库
贡献；组件只展示前 top 项 —— 图标行不带名称，悬停 title 显示
「语言名 百分比」；无图标语言回落纯文本标签保证可见。
"""

from __future__ import annotations

from typing import Any

from main.components._icons import icon_url
from main.components._theme import resolve_theme

DEFAULT_HEADER = "🧑‍💻 语言"
DEFAULT_TOP = 8
DEFAULT_ICON_HEIGHT = 48
_SEPARATOR = "&nbsp;&nbsp;·&nbsp;&nbsp;"


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染居中纯图标行（悬停见名称与占比），自动换行。"""
    resolve_theme(config)  # 提前校验 theme 合法性（视觉不直接用色）
    items = data if isinstance(data, list) else list(data.get("languages") or [])
    if not items:
        raise ValueError("languages 数据为空（数据源层未产出任何语言条目）")

    top = int(config.get("top", DEFAULT_TOP))
    icon_height = int(config.get("icon_height", DEFAULT_ICON_HEIGHT))
    header = str(config.get("header") or DEFAULT_HEADER)
    overrides = dict(config.get("icons") or {})

    units: list[str] = []
    for item in items[:top]:
        lang = str(item["lang"])
        pct = float(item.get("pct", 0.0))
        url = icon_url(lang, overrides)
        units.append(
            f'<img src="{url}" height="{icon_height}" alt="{lang}" title="{lang} {pct:.1f}%" />'
            if url
            else f"<sub><b>{lang}</b> {pct:.1f}%</sub>"
        )
    if not units:
        raise ValueError("languages 截取 top 后为空")

    body = f"  {_SEPARATOR.join(units)}"
    return "\n".join([f'<h3 align="center">{header}</h3>', "", '<p align="center">', body, "</p>"])
