"""templates/README.md.j2 单测：与流水线 assemble 的模板路径完全一致。

assemble 约定：上下文 = sections（按启用顺序的 {组件名: 片段} 映射）
+ profile（profile.yaml 全量）；Environment(FileSystemLoader(templates/),
autoescape=False, keep_trailing_newline=True)。本测试镜像该调用方式。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from jinja2 import Environment, FileSystemLoader

ROOT = Path(__file__).resolve().parents[1]
PROFILE_STUB: dict[str, Any] = {
    "theme": {"accent": "7aa2f7"},
    "timezone": "Asia/Shanghai",
}


def _render(sections: dict[str, str], profile: dict[str, Any]) -> str:
    env = Environment(
        loader=FileSystemLoader(ROOT / "templates"),
        autoescape=False,
        keep_trailing_newline=True,
    )
    return env.get_template("README.md.j2").render(sections=sections, profile=profile)


def test_marker_and_order_and_footer() -> None:
    sections = {
        "banner": "<p>BANNER</p>",
        "typing": "<p>TYPING</p>",
        "stats": "<p>STATS</p>",
    }
    out = _render(sections, PROFILE_STUB)
    assert out.startswith("<!-- AUTO-GENERATED")
    assert out.index("BANNER") < out.index("TYPING") < out.index("STATS")
    assert "section=footer&reversal=true" in out
    assert "0:1a1b26,100:7aa2f7" in out
    assert out.endswith("</p>\n")


def test_theme_defaults_when_keys_missing() -> None:
    out = _render({"stats": "X"}, {"theme": {}, "timezone": "UTC"})
    assert "0:1a1b26,100:7aa2f7" in out


def test_vertical_spacing_between_fragments() -> None:
    """竖排连续布局：片段之间恰好一个空行。"""
    out = _render({"first": "AAA", "second": "BBB"}, PROFILE_STUB)
    assert "AAA\n\nBBB" in out
