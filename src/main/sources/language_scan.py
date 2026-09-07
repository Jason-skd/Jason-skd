"""Language mapping, path exclusion filters and weight aggregation.

Weight = sum(added+deleted) over files the user actually touched. Vendored
code is excluded twice: profile.yaml path globs (primary, works everywhere)
and each repo's own ``.gitattributes`` ``linguist-vendored/generated``
markers (secondary guard, own repos only).
"""

from __future__ import annotations

from fnmatch import fnmatch
from pathlib import Path

EXTENSION_MAP: dict[str, str] = {
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

FILENAME_MAP: dict[str, str] = {
    "makefile": "Makefile",
    "gnumakefile": "Makefile",
    "dockerfile": "Dockerfile",
    "cmakelists.txt": "CMake",
    "rakefile": "Ruby",
    "gemfile": "Ruby",
}


def language_for(path: str) -> str | None:
    """Map a repo-relative path to a language name (None = not trackable)."""
    base = path.rsplit("/", 1)[-1].lower()
    if base in FILENAME_MAP:
        return FILENAME_MAP[base]
    dot = base.rfind(".")
    if dot <= 0:
        return None
    return EXTENSION_MAP.get(base[dot:])


class PathFilter:
    """Glob-based exclusion: profile.yaml patterns + repo .gitattributes guards."""

    def __init__(self, anchored: list[str], basename: list[str]) -> None:
        self.anchored = anchored
        self.basename = basename

    @classmethod
    def for_repo(cls, repo_dir: Path, extra_patterns: list[str]) -> PathFilter:
        anchored: list[str] = []
        basename: list[str] = []
        for pat in extra_patterns + _gitattributes_patterns(repo_dir):
            _add_pattern(anchored, basename, pat)
        return cls(anchored, basename)

    def excluded(self, path: str) -> bool:
        base = path.rsplit("/", 1)[-1]
        return any(fnmatch(path, p) for p in self.anchored) or any(
            fnmatch(base, p) for p in self.basename
        )


def _add_pattern(anchored: list[str], basename: list[str], pattern: str) -> None:
    pat = pattern.strip().rstrip("/")
    if not pat or pat.startswith("#"):
        return
    pat = pat.lstrip("/")
    if "/" in pat:
        variants = [pat]
        if pat.startswith("**/"):
            variants.append(pat[3:])  # "**/vendor/**" must also match top-level "vendor/..."
        anchored.extend(variants)
    else:
        basename.append(pat)


def _gitattributes_patterns(repo_dir: Path) -> list[str]:
    """Collect linguist-vendored/generated patterns from a repo's .gitattributes."""
    ga = repo_dir / ".gitattributes"
    if not ga.is_file():
        return []
    patterns: list[str] = []
    for line in ga.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        if any(p.startswith(("linguist-vendored", "linguist-generated")) for p in parts[1:]):
            patterns.append(parts[0])
    return patterns


def aggregate_languages(
    per_repo: dict[str, dict[str, int]],
    *,
    exclude_languages: list[str],
    top: int | None = None,
) -> list[dict[str, object]]:
    """Aggregate per-repo weights into a sorted [{lang, weight, pct}] list."""
    totals: dict[str, int] = {}
    for weights in per_repo.values():
        for lang, weight in weights.items():
            if lang in exclude_languages or weight <= 0:
                continue
            totals[lang] = totals.get(lang, 0) + weight
    grand = sum(totals.values())
    ordered = sorted(totals.items(), key=lambda kv: (-kv[1], kv[0]))
    if top is not None:
        ordered = ordered[:top]
    return [
        {
            "lang": lang,
            "weight": weight,
            "pct": round(weight * 100.0 / grand, 2) if grand else 0.0,
        }
        for lang, weight in ordered
    ]
