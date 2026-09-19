"""Unit tests: language mapping, path filters, aggregation."""

from __future__ import annotations

import logging
from pathlib import Path

from main.sources.language_scan import (
    EXTENSION_MAP,
    FILENAME_MAP,
    PathFilter,
    aggregate_languages,
    language_for,
    language_type,
)


def test_language_for_extensions() -> None:
    assert language_for("src/main.c") == "C"
    assert language_for("include/util.h") == "C"
    assert language_for("a/b/app.py") == "Python"
    assert language_for("zig/main.zig") == "Zig"
    assert language_for("ui/src/App.tsx") == "TypeScript"
    assert language_for("core.kt") == "Kotlin"
    assert language_for("x.unknownext") is None
    assert language_for("noext") is None


def test_language_for_special_filenames() -> None:
    assert language_for("Makefile") == "Makefile"
    assert language_for("build/Dockerfile") == "Dockerfile"
    assert language_for("CMakeLists.txt") == "CMake"


def test_path_filter_profile_patterns() -> None:
    filt = PathFilter.for_repo(Path("/nonexistent"), ["**/vendor/**", "**/third_party/**"])

    assert filt.excluded("vendor/lib/foo.c")
    assert filt.excluded("src/vendor/lib/foo.c")
    assert filt.excluded("third_party/openssl/a.c")
    assert not filt.excluded("src/main.c")


def test_path_filter_gitattributes_guard(tmp_path: Path) -> None:
    (tmp_path / ".gitattributes").write_text(
        "# guard\n"
        "ext/** linguist-vendored\n"
        "generated.c linguist-generated=true\n"
        "*.snap linguist-vendored -diff\n",
        encoding="utf-8",
    )
    filt = PathFilter.for_repo(tmp_path, [])

    assert filt.excluded("ext/foo.c")
    assert filt.excluded("deep/nested/generated.c")  # no-slash patterns match at any depth
    assert filt.excluded("anywhere/generated.c")
    assert filt.excluded("tests/x.snap")
    assert not filt.excluded("src/other.c")


def test_aggregate_languages_weights_pct_and_filters() -> None:
    per_repo = {
        "a": {"C": 100, "Python": 100},
        "b": {"C": 300, "Zig": 0, "Markdown": 50},
        "c": {},  # empty repo contributes nothing
    }
    out = aggregate_languages(per_repo, exclude_languages=["Markdown"], top=3)

    assert out == [
        {"lang": "C", "weight": 400, "pct": 80.0},
        {"lang": "Python", "weight": 100, "pct": 20.0},
    ]  # Zig dropped (zero weight), Markdown excluded


def test_aggregate_languages_empty() -> None:
    assert aggregate_languages({}, exclude_languages=[]) == []


# ── issue #8：vendored linguist 快照 + 类型白名单 ─────────────────────────────

# v1.2 之前的手写扩展名表，作为行为兼容基准（快照须与之一致，除 ALLOWED_DIFFS）
LEGACY_EXTENSION_MAP: dict[str, str] = {
    ".c": "C",
    ".h": "C",
    ".py": "Python",
    ".pyi": "Python",
    ".zig": "Zig",
    ".ts": "TypeScript",
    ".tsx": "TypeScript",
    ".mts": "TypeScript",
    ".cts": "TypeScript",
    ".js": "JavaScript",
    ".jsx": "JavaScript",
    ".mjs": "JavaScript",
    ".cjs": "JavaScript",
    ".kt": "Kotlin",
    ".kts": "Kotlin",
    ".go": "Go",
    ".rs": "Rust",
    ".cpp": "C++",
    ".cc": "C++",
    ".cxx": "C++",
    ".hpp": "C++",
    ".hh": "C++",
    ".hxx": "C++",
    ".cs": "C#",
    ".java": "Java",
    ".rb": "Ruby",
    ".php": "PHP",
    ".swift": "Swift",
    ".m": "Objective-C",
    ".mm": "Objective-C",
    ".lua": "Lua",
    ".sql": "SQL",
    ".sh": "Shell",
    ".bash": "Shell",
    ".zsh": "Shell",
    ".fish": "Shell",
    ".html": "HTML",
    ".htm": "HTML",
    ".css": "CSS",
    ".scss": "SCSS",
    ".sass": "SCSS",
    ".less": "Less",
    ".vue": "Vue",
    ".svelte": "Svelte",
    ".md": "Markdown",
    ".markdown": "Markdown",
    ".mdx": "Markdown",
    ".json": "JSON",
    ".yaml": "YAML",
    ".yml": "YAML",
    ".toml": "TOML",
    ".xml": "XML",
    ".r": "R",
    ".jl": "Julia",
    ".dart": "Dart",
    ".scala": "Scala",
    ".ex": "Elixir",
    ".exs": "Elixir",
    ".erl": "Erlang",
    ".hs": "Haskell",
    ".pl": "Perl",
    ".asm": "Assembly",
    ".s": "Assembly",
    ".ipynb": "Jupyter Notebook",
    ".proto": "Protocol Buffers",
    ".gradle": "Groovy",
    ".cmake": "CMake",
}

# 有意接受的差异：linguist 语义上更正确（独立语言/正确归类），非快照映射事故
ALLOWED_DIFFS: dict[str, str] = {
    ".fish": "fish",  # 独立编程语言，不再并入 Shell
    ".sass": "Sass",  # Sass 与 SCSS 本就是两种语言
    ".proto": "Protocol Buffer",  # linguist 官方语言名
    ".gradle": "Gradle",  # type=data，构建文件自动出局
}

LEGACY_FILENAME_MAP: dict[str, str] = {
    "makefile": "Makefile",
    "gnumakefile": "Makefile",
    "dockerfile": "Dockerfile",
    "cmakelists.txt": "CMake",
    "rakefile": "Ruby",
    "gemfile": "Ruby",
}


def test_vendored_extension_map_matches_legacy() -> None:
    for ext, legacy_lang in LEGACY_EXTENSION_MAP.items():
        expected = ALLOWED_DIFFS.get(ext, legacy_lang)
        assert EXTENSION_MAP[ext] == expected, f"{ext}: {EXTENSION_MAP[ext]} != {expected}"


def test_vendored_filename_map_matches_legacy() -> None:
    for name, legacy_lang in LEGACY_FILENAME_MAP.items():
        assert FILENAME_MAP[name] == legacy_lang, name


def test_language_type_lookup() -> None:
    assert language_type("Python") == "programming"
    assert language_type("CSS") == "markup"
    assert language_type("YAML") == "data"
    assert language_type("Markdown") == "prose"
    assert language_type("NotALanguageAtAll") is None


def test_aggregate_languages_type_whitelist_filters_and_renormalises() -> None:
    per_repo = {"a": {"Python": 60, "YAML": 30, "Markdown": 10, "CSS": 10}}
    out = aggregate_languages(
        per_repo, exclude_languages=[], allowed_types={"programming", "markup"}
    )
    # YAML(data)/Markdown(prose) 出局，占比在剩余集合上重新归一
    assert [(o["lang"], o["pct"]) for o in out] == [("Python", 85.71), ("CSS", 14.29)]


def test_aggregate_languages_whitelist_can_drop_markup() -> None:
    out = aggregate_languages(
        {"r": {"Go": 70, "CSS": 30}}, exclude_languages=[], allowed_types={"programming"}
    )
    assert [o["lang"] for o in out] == ["Go"]


def test_aggregate_languages_unknown_counted_with_warning(caplog) -> None:
    per_repo = {"r": {"Python": 70, "TotallyNewLang": 30}}
    with caplog.at_level(logging.WARNING, logger="main.sources.language_scan"):
        out = aggregate_languages(per_repo, exclude_languages=[], allowed_types={"programming"})
    # 未知语言默认计入（不被静默吞掉），且有 WARNING
    assert [o["lang"] for o in out] == ["Python", "TotallyNewLang"]
    assert any("TotallyNewLang" in rec.message for rec in caplog.records)


def test_manual_exclude_overrides_whitelist() -> None:
    # CMake 本身是 programming；excludes.languages 手动微调优先级最高
    out = aggregate_languages(
        {"r": {"Go": 80, "CMake": 20}},
        exclude_languages=["CMake"],
        allowed_types={"programming", "markup"},
    )
    assert [o["lang"] for o in out] == ["Go"]


def test_allowed_types_none_keeps_unfiltered_behaviour() -> None:
    out = aggregate_languages({"r": {"Go": 50, "YAML": 50}}, exclude_languages=[])
    assert [o["lang"] for o in out] == ["Go", "YAML"]
