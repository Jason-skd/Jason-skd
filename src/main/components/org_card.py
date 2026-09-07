"""org_card 组件：纯品牌卡（logo + 组织名，绝不显示数字）。

锁定决策（issue #1）：restrictedContributionsCount 混含本人私有仓库贡献，
无法按组织拆分，因此组织卡不做任何统计展示，只做品牌露出。
"""

from __future__ import annotations

from typing import Any

DEFAULT_HEADER = "🏫 我所在的组织"
DEFAULT_LOGO_HEIGHT = 48


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染组织品牌链接块；data = data/org.json。"""
    name = str(data["name"]).strip()
    url = str(data["url"]).strip()
    logo = str(data.get("logo") or "").strip()
    if not name or not url:
        raise ValueError("org 数据缺少 name 或 url（org.json）")

    header = config.get("header", DEFAULT_HEADER)
    logo_height = int(config.get("logo_height", DEFAULT_LOGO_HEIGHT))
    icon = f'<img src="{logo}" width="{logo_height}" alt="{name}" /> ' if logo else ""

    lines = [f'<h3 align="left">{header}</h3>', "", "<p>", f'  <a href="{url}">']
    if icon:
        lines.append(f"    {icon}")
    lines += [f"    <b>{name}</b>", "  </a>", "</p>"]
    return "\n".join(lines)
