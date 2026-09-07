"""Unit tests: language mapping, path filters, aggregation."""

from __future__ import annotations

from pathlib import Path

from main.sources.language_scan import (
    PathFilter,
    aggregate_languages,
    language_for,
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
