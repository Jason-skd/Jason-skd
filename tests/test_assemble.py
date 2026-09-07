"""assemble：注册表、按序拼接、校验门、模板钩子、原子写。"""

import json
import os
from pathlib import Path
from typing import Any

import pytest
from conftest import REPO_ROOT

from main.assemble import (
    GENERATED_MARKER,
    assemble,
    fixture_registry,
    render_all,
    write_atomic,
)
from main.config import load_profile


def _profile(
    tmp_path: Path, sections: tuple[str, ...] = ("banner", "typing", "stats")
) -> dict[str, Any]:
    profile = load_profile(REPO_ROOT / "profile.yaml")
    profile["sections"] = list(sections)
    return profile


def _stub_registry() -> dict[str, Any]:
    def banner(config: dict[str, Any], data: dict[str, Any]) -> str:
        return "<banner>"

    def typing(config: dict[str, Any], data: dict[str, Any]) -> str:
        return "<typing>"

    def stats(config: dict[str, Any], data: dict[str, Any]) -> str:
        assert data["stars"] == 21  # data 必须是 stats.json 反序列化结果
        return "<stats>"

    return {"banner": banner, "typing": typing, "stats": stats}


def _stats_data() -> dict[str, Any]:
    return {
        "stats": json.loads(
            (REPO_ROOT / "fixtures" / "data" / "stats.json").read_text("utf-8")
        )
    }


def test_render_all_passes_contract_data(tmp_path: Path) -> None:
    outputs = render_all(_profile(tmp_path), _stats_data(), _stub_registry())
    assert list(outputs) == ["banner", "typing", "stats"]  # 按 profile.yaml 顺序


def test_missing_component_refused(tmp_path: Path) -> None:
    registry = {name: fn for name, fn in _stub_registry().items() if name != "typing"}
    with pytest.raises(Exception, match="missing components"):
        render_all(_profile(tmp_path), _stats_data(), registry)


def test_render_exception_wrapped(tmp_path: Path) -> None:
    def boom(config: dict[str, Any], data: dict[str, Any]) -> str:
        raise RuntimeError("boom")

    profile = _profile(tmp_path, sections=("stats",))
    with pytest.raises(Exception, match="raised"):
        render_all(profile, _stats_data(), {"stats": boom})


def test_empty_output_refused(tmp_path: Path) -> None:
    profile = _profile(tmp_path, sections=("stats",))
    with pytest.raises(Exception, match="empty output"):
        render_all(profile, _stats_data(), {"stats": lambda c, d: "   "})


def test_assemble_concat_order_and_marker(tmp_path: Path) -> None:
    profile = _profile(tmp_path, sections=("banner", "typing"))
    content = assemble(profile, {}, _stub_registry(), tmp_path)
    assert content.startswith(GENERATED_MARKER)
    assert content.index("<banner>") < content.index("<typing>")


def test_assemble_template_hook(tmp_path: Path) -> None:
    (tmp_path / "templates").mkdir()
    (tmp_path / "templates" / "README.md.j2").write_text(
        "T:{{ sections.banner }}|{{ sections.typing }}\n", encoding="utf-8"
    )
    profile = _profile(tmp_path, sections=("banner", "typing"))
    content = assemble(profile, {}, _stub_registry(), tmp_path)
    assert content == "T:<banner>|<typing>\n"


def test_fixture_registry_reads_outputs(tmp_path: Path) -> None:
    registry = fixture_registry(REPO_ROOT / "fixtures")
    assert set(registry) == {
        "banner",
        "typing",
        "stats",
        "languages",
        "org_card",
        "recent_project",
    }
    assert "capsule-render" in registry["banner"]({}, {})


def test_write_atomic_replaces_and_cleans(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "README.md"
    write_atomic(target, "v1\n")
    assert target.read_text(encoding="utf-8") == "v1\n"

    def failing_replace(src: Any, dst: Any) -> None:
        raise OSError("disk on fire")

    monkeypatch.setattr(os, "replace", failing_replace)
    with pytest.raises(OSError):
        write_atomic(target, "v2\n")
    monkeypatch.undo()
    assert target.read_text(encoding="utf-8") == "v1\n"  # 旧文件原样
    assert list(tmp_path.glob(".README.md.*.tmp")) == []  # 临时文件已清理
