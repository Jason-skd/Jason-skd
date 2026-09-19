"""Language mapping, path exclusion filters and weight aggregation.

Weight = sum(added+deleted) over files the user actually touched. Vendored
code is excluded twice: profile.yaml path globs (primary, works everywhere)
and each repo's own ``.gitattributes`` ``linguist-vendored/generated``
markers (secondary guard, own repos only).

语言识别与类型白名单（issue #8）：扩展名/文件名映射和 programming|markup|data|prose
类型均来自同一份 vendored 快照 ``linguist_data.json``（由
``python -m main.sources.linguist_regen`` 从上游 languages.yml 生成，离线确定性）。
辅助格式（data/prose，如 YAML/JSON/SQL/Markdown）由 ``allowed_types`` 白名单过滤，
不再依赖手动黑名单；``excludes.languages`` 仅保留作用户手动微调（优先级最高）。
映射表里不存在的语言默认计入并打 WARNING，避免新语言被静默吞掉。
"""

from __future__ import annotations

import json
import logging
from fnmatch import fnmatch
from pathlib import Path

logger = logging.getLogger(__name__)


def _load_snapshot() -> dict:
    with (Path(__file__).parent / "linguist_data.json").open(encoding="utf-8") as f:
        return json.load(f)


_SNAPSHOT = _load_snapshot()
#: 语言名 -> linguist type（programming|markup|data|prose）
LINGUIST_TYPES: dict[str, str] = _SNAPSHOT["language_types"]
#: 扩展名（小写含点）-> 语言名
EXTENSION_MAP: dict[str, str] = _SNAPSHOT["extensions"]
#: 文件名（basename 小写）-> 语言名
FILENAME_MAP: dict[str, str] = _SNAPSHOT["filenames"]


def language_for(path: str) -> str | None:
    """Map a repo-relative path to a language name (None = not trackable)."""
    base = path.rsplit("/", 1)[-1].lower()
    if base in FILENAME_MAP:
        return FILENAME_MAP[base]
    dot = base.rfind(".")
    if dot <= 0:
        return None
    return EXTENSION_MAP.get(base[dot:])


def language_type(language: str) -> str | None:
    """Linguist type of a language name; None = 不在 vendored 映射中。"""
    return LINGUIST_TYPES.get(language)


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
    allowed_types: set[str] | None = None,
) -> list[dict[str, object]]:
    """Aggregate per-repo weights into a sorted [{lang, weight, pct}] list.

    过滤优先级：``exclude_languages``（用户手动微调）> ``allowed_types``
    （linguist 类型白名单，None = 不过滤）> 无。白名单外的语言静默跳过
    （data/prose 属预期行为）；不在 linguist 映射中的未知语言默认计入并
    打 WARNING。占比在过滤后的集合上重新归一。
    """
    totals: dict[str, int] = {}
    for weights in per_repo.values():
        for lang, weight in weights.items():
            if lang in exclude_languages or weight <= 0:
                continue
            if allowed_types is not None:
                lang_type = LINGUIST_TYPES.get(lang)
                if lang_type is None:
                    logger.warning(
                        "未知语言 %r 不在 linguist 映射中，默认计入统计（可加入"
                        " excludes.languages 排除）",
                        lang,
                    )
                elif lang_type not in allowed_types:
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
