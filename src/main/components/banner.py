"""banner 组件：顶部波浪飘带（capsule-render 官方实例，v1 直链）。

渐变 = 深夜底色 → 主色靛蓝（靛夜青）；自部署实例待用户提供域名后切换
``instance`` 配置即可，query 参数不变。
注意：sections 契约不允许重复项，底部飘带由 templates/README.md.j2 统一追加。
"""

from __future__ import annotations

from typing import Any

from main.components._theme import resolve_theme

DEFAULT_INSTANCE = "https://capsule-render.vercel.app/api"
DEFAULT_HEIGHT = 200


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染 header 波浪图；data 未使用（无数据组件）。"""
    theme = resolve_theme(config)
    instance = str(config.get("instance", DEFAULT_INSTANCE)).rstrip("/")
    height = int(config.get("height", DEFAULT_HEIGHT))
    if height <= 0:
        raise ValueError(f"banner.height 必须为正整数，得到 {height}")
    color = f"0:{theme['base']},100:{theme['accent']}"
    url = f"{instance}?type=waving&color={color}&height={height}&section=header"
    return f'<p align="center">\n  <img src="{url}" alt="banner" width="100%" />\n</p>'
