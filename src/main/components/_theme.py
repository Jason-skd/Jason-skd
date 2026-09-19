"""靛夜青（Tokyo Night 调性）主题 —— 组件层唯一定色处。

精确色值定稿（已回填 issue #1）：

==========  ========  =========================================
键          色值      用途
==========  ========  =========================================
``base``    #1A1B26   深夜底色：banner 渐变起点
``accent``  #7AA2F7   单一深色主色 · 靛蓝：渐变终点/徽章/打字文本
``cyan``    #7DCFFF   点缀 · 青（v1 备用，少用）
==========  ========  =========================================

profile.yaml 的 theme 块可逐键覆盖；缺键回落到本模块默认值。
"""

from __future__ import annotations

from typing import Any

DEFAULT_THEME: dict[str, str] = {
    "base": "1a1b26",
    "accent": "7aa2f7",
    "cyan": "7dcfff",
}

_HEX_DIGITS = frozenset("0123456789abcdef")


def resolve_theme(config: dict[str, Any]) -> dict[str, str]:
    """合并 profile.yaml theme 覆盖与默认色板；非法 hex 抛 ValueError。"""
    overrides = config.get("theme") or {}
    if not isinstance(overrides, dict):
        raise TypeError(f"theme 必须是映射，得到 {type(overrides).__name__}")
    merged = {
        **DEFAULT_THEME,
        **{
            key: str(value).lstrip("#").lower()
            for key, value in overrides.items()
            if isinstance(value, str) and value.strip()
        },
    }
    for key in ("base", "accent", "cyan"):
        value = merged[key]
        if len(value) != 6 or not set(value) <= _HEX_DIGITS:
            raise ValueError(f"theme.{key} 不是合法 6 位 hex：{value!r}")
    return merged
