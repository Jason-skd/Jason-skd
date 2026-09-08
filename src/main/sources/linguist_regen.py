"""Regenerate the vendored linguist snapshot (issue #8).

数据源：github-linguist/linguist 的 lib/linguist/languages.yml。
产物：同目录下的 ``linguist_data.json``（运行时唯一依赖，离线确定性）。

映射政策（保持与旧手写映射的行为兼容，改动可控）：
  1. 扩展名/文件名反向映射按 languages.yml 的文件顺序"首见优先"；
  2. 已知多语言争夺同一扩展名的（如 ``.m``/``.sql``），由 ``EXTENSION_OVERRIDES``
     显式裁定，沿用 linguist 常见判定与旧手写表一致的结果；
  3. 每种语言只保留 ``type``（programming|markup|data|prose）供白名单过滤。

用法（更新快照时手动执行，运行时不联网）::

    gh api repos/github-linguist/linguist/contents/lib/linguist/languages.yml \\
       -H "Accept: application/vnd.github.raw" > /tmp/languages.yml
    uv run python -m main.sources.linguist_regen /tmp/languages.yml
"""

from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path
from typing import Any

import yaml

# 首见优先不足以给出正确答案的扩展名（多语言争夺），裁定结果对齐 linguist
# 常见判定与旧手写 EXTENSION_MAP（见 tests/test_language_scan.py 的兼容性测试）。
EXTENSION_OVERRIDES: dict[str, str] = {
    ".h": "C",  # C / C++ / Objective-C 争夺；无启发式时按 C 计
    ".m": "Objective-C",  # 首见会得到 Limbo/MATLAB 等
    ".mm": "Objective-C",
    ".sql": "SQL",  # 首见会得到 PLSQL
    ".pl": "Perl",  # Perl / Prolog / Raku
    ".r": "R",
    ".ts": "TypeScript",
    ".tsx": "TypeScript",  # linguist 有独立 TSX 语言；统计上并入 TypeScript 避免碎片化
    ".rs": "Rust",  # 首见会得到 RenderScript
    ".php": "PHP",  # 首见会得到 Hack
    ".html": "HTML",  # 首见会得到 Ecmarkup
    ".md": "Markdown",  # 首见会得到 GCC Machine Description
    ".mdx": "Markdown",  # linguist 的 MDX 是 markup 会漏进白名单；并入 Markdown(prose)
    ".yaml": "YAML",  # 首见会得到 MiniYAML
    ".yml": "YAML",
    ".vsixmanifest": "XML",
}

# 有意接受的首见结果（与旧手写表不同但 linguist 语义更正确，见兼容性测试的 ALLOWED_DIFFS）：
#   .fish -> fish（独立语言，programming）      .sass -> Sass（与 SCSS 是两种语言）
#   .proto -> Protocol Buffer（官方名单数）      .gradle -> Gradle（data，自动出局）

# 文件名（basename 小写后匹配）覆盖：旧手写 FILENAME_MAP 的可移植写法。
FILENAME_OVERRIDES: dict[str, str] = {
    "makefile": "Makefile",
    "gnumakefile": "Makefile",
    "dockerfile": "Dockerfile",
}


def build_snapshot(raw: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """languages.yml 原始映射 -> 精简快照 dict。"""
    languages: dict[str, str] = {}
    extensions: dict[str, str] = {}
    filenames: dict[str, str] = {}
    for name, spec in raw.items():
        lang_type = spec.get("type")
        if lang_type not in ("programming", "markup", "data", "prose"):
            continue  # group 成员等无 type 的条目跳过（统计归并到父语言，超出本表职责）
        languages[name] = lang_type
        for ext in spec.get("extensions") or []:
            extensions.setdefault(ext, name)
        for fn in spec.get("filenames") or []:
            filenames.setdefault(fn.lower(), name)
    extensions.update(EXTENSION_OVERRIDES)
    filenames.update(FILENAME_OVERRIDES)
    return {
        "meta": {
            "source": "github-linguist/linguist lib/linguist/languages.yml",
            "generated": date.today().isoformat(),
            "languages": len(languages),
        },
        "language_types": languages,
        "extensions": extensions,
        "filenames": filenames,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    src = Path(argv[1])
    raw = yaml.safe_load(src.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not raw:
        print(f"invalid languages.yml: {src}", file=sys.stderr)
        return 1
    snapshot = build_snapshot(raw)
    dest = Path(__file__).parent / "linguist_data.json"
    dest.write_text(
        json.dumps(snapshot, ensure_ascii=False, sort_keys=True, indent=1) + "\n",
        encoding="utf-8",
    )
    print(f"written: {dest} ({dest.stat().st_size} bytes, ")
    print(f"  {len(snapshot['language_types'])} languages, ")
    print(f"  {len(snapshot['extensions'])} extensions, {len(snapshot['filenames'])} filenames)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
