"""devicon 语言图标映射（CDN 固定 @latest tag）。

映射条目均已对 devicons/devicon 仓库逐一核实存在；
未覆盖语言回落为无图标纯文本，或经组件配置 ``icons`` 手工指定：
``{"语言名": "slug/variant"}``（variant 不含 slug 前缀，最终文件名
= ``<slug>-<variant>.svg``），例如 ``{"C": "c/line"}`` → ``c/c-line.svg``。
"""

from __future__ import annotations

from collections.abc import Mapping

_DEVICON_CDN = "https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons"

# 语言名 → (slug, variant)；列表为 2026-09 gh api 逐一核实结果
DEVICON_MAP: dict[str, tuple[str, str]] = {
    "C": ("c", "original"),
    "Python": ("python", "original"),
    "Zig": ("zig", "original"),
    "TypeScript": ("typescript", "original"),
    "JavaScript": ("javascript", "original"),
    "Kotlin": ("kotlin", "original"),
    "C++": ("cplusplus", "original"),
    "C#": ("csharp", "original"),
    "Go": ("go", "original-wordmark"),
    "HTML": ("html5", "original"),
    "CSS": ("css3", "original"),
    "Shell": ("bash", "original"),
    "Bash": ("bash", "original"),
    "Markdown": ("markdown", "original"),
}


def icon_url(lang: str, overrides: Mapping[str, str] | None = None) -> str | None:
    """返回语言图标 CDN 直链；无匹配（且无覆盖）时返回 None（纯文本回落）。"""
    spec = (overrides or {}).get(lang)
    if spec is None:
        spec = DEVICON_MAP.get(lang)
        if spec is None:
            return None
        slug, variant = spec
    else:
        slug, _, variant = str(spec).partition("/")
        if not variant:
            variant = "original"
    return f"{_DEVICON_CDN}/{slug}/{slug}-{variant}.svg"
