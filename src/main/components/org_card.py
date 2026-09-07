"""org_card 组件：纯品牌卡（放大 logo 带组织链接，v1.1 不带文字）。

锁定决策（issue #1）：restrictedContributionsCount 混含本人私有仓库贡献，
无法按组织拆分，因此组织卡不做任何统计展示，只做品牌露出；
名称保留在 alt / title（悬停与无障碍可读）。
"""

from __future__ import annotations

from typing import Any

DEFAULT_HEADER = "🏫 我所在的组织"
DEFAULT_LOGO_HEIGHT = 96


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染组织 logo 链接块；data = data/org.json。"""
    name = str(data["name"]).strip()
    url = str(data["url"]).strip()
    logo = str(data.get("logo") or "").strip()
    if not name or not url:
        raise ValueError("org 数据缺少 name 或 url（org.json）")
    if not logo:
        raise ValueError("org 数据缺少 logo（org.json）—— 纯 logo 卡无回落内容")

    header = config.get("header", DEFAULT_HEADER)
    logo_height = int(config.get("logo_height", DEFAULT_LOGO_HEIGHT))
    icon = f'<img src="{logo}" width="{logo_height}" alt="{name}" title="{name}" />'

    return "\n".join(
        [
            f'<h3 align="center">{header}</h3>',
            "",
            '<p align="center">',
            f'  <a href="{url}">{icon}</a>',
            "</p>",
        ]
    )
