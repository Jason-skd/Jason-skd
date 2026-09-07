"""六组件离线单测（issue #3 验收：完全离线、fixtures 驱动、逐字节快照）。

fixtures/components/<name>/ 三件套：
- config.json —— 模拟流水线 config.section_config 注入形状
  （{"theme", "timezone", "excludes", **组件配置切片}）；
- data.json —— 模拟 data/*.json 反序列化结果（无数据组件为空 dict）；
- expected.md —— render() 输出快照（含结尾换行）。
"""

from __future__ import annotations

import importlib
import json
from pathlib import Path
from typing import Any

import pytest

FIXTURES = Path(__file__).parent / "fixtures" / "components"
COMPONENT_NAMES = (
    "banner",
    "typing",
    "stats",
    "languages",
    "org_card",
    "recent_project",
)


def _load(name: str, kind: str) -> Any:
    return json.loads((FIXTURES / name / f"{kind}.json").read_text(encoding="utf-8"))


def _module(name: str) -> Any:
    return importlib.import_module(f"main.components.{name}")


@pytest.mark.parametrize("name", COMPONENT_NAMES)
def test_render_matches_expected_snapshot(name: str) -> None:
    """输出与 expected.md 逐字节一致（确定性渲染）。"""
    rendered = _module(name).render(_load(name, "config"), _load(name, "data"))
    expected = (FIXTURES / name / "expected.md").read_text(encoding="utf-8")
    assert rendered + "\n" == expected


@pytest.mark.parametrize("name", COMPONENT_NAMES)
def test_registry_contract(name: str) -> None:
    """流水线 import_registry 依赖的契约：main.components.<name>.render 可调用。"""
    assert callable(getattr(_module(name), "render", None))


@pytest.mark.parametrize("name", COMPONENT_NAMES)
def test_output_non_empty(name: str) -> None:
    """校验门要求：组件产出非空（空串会被整体拒绝）。"""
    rendered = _module(name).render(_load(name, "config"), _load(name, "data"))
    assert isinstance(rendered, str) and rendered.strip()


def test_typing_rejects_missing_lines() -> None:
    """typing.lines 是用户日常编辑点，缺失/为空必须显式报错而非静默。"""
    with pytest.raises(ValueError, match="typing.lines"):
        _module("typing").render({"theme": {}, "timezone": "UTC", "excludes": {}}, {})


def test_recent_project_placeholder_without_repo() -> None:
    """recent 数据缺席时渲染占位行，保持非空以满足校验门。"""
    rendered = _module("recent_project").render(
        {"theme": {}, "timezone": "UTC", "excludes": {}}, {"repo": ""}
    )
    assert "暂无可展示" in rendered


def test_languages_rejects_empty_data() -> None:
    with pytest.raises(ValueError, match="语言条目"):
        _module("languages").render(
            {"theme": {}, "timezone": "UTC", "excludes": {}}, []
        )


def test_banner_rejects_bad_theme_hex() -> None:
    with pytest.raises(ValueError, match="hex"):
        _module("banner").render(
            {"theme": {"accent": "zzzzzz"}, "timezone": "UTC", "excludes": {}}, {}
        )


def test_languages_icon_override() -> None:
    """未覆盖语言走 icons 覆盖映射（slug/variant，文件名 = slug-variant.svg）。"""
    data = [{"lang": "MyLang", "weight": 10, "pct": 100.0}]
    rendered = _module("languages").render(
        {
            "theme": {},
            "timezone": "UTC",
            "excludes": {},
            "icons": {"MyLang": "c/line"},
        },
        data,
    )
    assert "icons/c/c-line.svg" in rendered


def test_languages_unknown_lang_text_fallback() -> None:
    """无图标语言回落为纯文本标签，不产生悬空 img。"""
    data = [{"lang": "UnknownLang", "weight": 1, "pct": 100.0}]
    rendered = _module("languages").render(
        {"theme": {}, "timezone": "UTC", "excludes": {}}, data
    )
    assert "<img" not in rendered
    assert "<b>UnknownLang</b> 100.0%" in rendered


def test_stats_shows_private_footnote() -> None:
    """锁定口径脚注必须可见（不藏在 HTML 注释里）。"""
    rendered = _module("stats").render(_load("stats", "config"), _load("stats", "data"))
    assert "含 320 条私有贡献" in rendered
    assert "<!--" not in rendered


def test_stats_degraded_marker() -> None:
    data = _load("stats", "data") | {"degraded": True}
    rendered = _module("stats").render(
        {"theme": {}, "timezone": "UTC", "excludes": {}}, data
    )
    assert "降级口径" in rendered


def test_theme_overrides_apply() -> None:
    """profile.yaml theme 覆盖生效（含 # 前缀与大写容错）。"""
    rendered = _module("banner").render(
        {"theme": {"base": "#10101A", "accent": "7AA2F7"}, "height": 100}, {}
    )
    assert "0:10101a,100:7aa2f7" in rendered
