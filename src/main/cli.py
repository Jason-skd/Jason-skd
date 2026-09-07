"""流水线编排：拉数 → 渲染 → 校验 → 写 README（issue #4）。"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

from main.assemble import (
    AssemblyError,
    assemble,
    fixture_registry,
    import_registry,
    write_atomic,
)
from main.config import ConfigError, load_profile

logger = logging.getLogger("main")

EXIT_OK = 0
EXIT_GATE = 1  # 校验门拒绝（组件缺失/失败/空产出）
EXIT_CONFIG = 2  # 配置/参数/数据错误

DATA_FILES = ("stats", "org", "languages", "recent")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="main",
        description="Jason-skd 动态主页流水线：拉数 → 渲染 → 校验 → 写 README",
    )
    parser.add_argument("--config", default="profile.yaml", type=Path, help="默认 profile.yaml")
    parser.add_argument("--output", default=None, type=Path, help="默认 README.md（config 同目录）")
    parser.add_argument("--data-dir", default=None, type=Path, help="默认 config 同目录 data/")
    parser.add_argument(
        "--fixtures",
        default=None,
        type=Path,
        metavar="DIR",
        help="离线 fixture 模式：读 DIR/data 与 DIR/components_output",
    )
    parser.add_argument("--dry-run", action="store_true", help="只校验并打印到 stdout，不写文件")
    return parser


def load_data_dir(data_dir: Path) -> dict[str, Any]:
    data_map: dict[str, Any] = {}
    for name in DATA_FILES:
        path = data_dir / f"{name}.json"
        if not path.is_file():
            raise ConfigError(f"data 文件缺失: {path}")
        data_map[name] = json.loads(path.read_text(encoding="utf-8"))
    return data_map


def resolve_token() -> str | None:
    """PAT 优先，其次 Actions 的 GITHUB_TOKEN；缺席即降级公开口径。"""
    return os.environ.get("PROFILE_PAT") or os.environ.get("GITHUB_TOKEN") or None


def provision_data(args: argparse.Namespace, config_path: Path) -> dict[str, Any]:
    """fixtures 模式读本地样例；否则读 data/ 或调用 sources 层（issue #2）。"""
    if args.fixtures is not None:
        return load_data_dir(args.fixtures / "data")
    data_dir = args.data_dir or (config_path.parent / "data")
    if data_dir.is_dir():
        return load_data_dir(data_dir)
    try:
        from main.sources import collect  # type: ignore[import-not-found]
    except ModuleNotFoundError as exc:
        raise ConfigError(
            "sources 层（issue #2）尚未集成，且无现成 data/ 目录；离线演示请用 --fixtures <dir>"
        ) from exc
    payloads, summary = collect(config_path, resolve_token(), with_summary=True)  # type: ignore[union-attr,misc]
    for item in summary.get("reposSkipped") or []:
        logger.warning(
            "channel-2 跳过仓库 %s：%s（该仓库未计入语言/最近动态统计）",
            item.get("repo"),
            item.get("reason"),
        )
    if summary.get("degraded"):
        logger.warning(
            "本次数据为降级口径（reposScanned=%s）——语言/最近动态可能不完整，详见上方逐仓库原因",
            summary.get("reposScanned"),
        )
    return payloads


def run(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    args = build_parser().parse_args(argv)
    config_path = args.config
    try:
        profile = load_profile(config_path)
        data_map = provision_data(args, config_path)
        if args.fixtures is not None or resolve_token() is None:
            logger.warning("降级口径：fixture 数据或无 PAT 公开口径")
        repo_root = config_path.parent
        registry = fixture_registry(args.fixtures) if args.fixtures else import_registry()
        content = assemble(profile, data_map, registry, repo_root)
    except ConfigError as exc:
        logger.error("配置错误：%s", exc)
        return EXIT_CONFIG
    except AssemblyError as exc:
        logger.error("校验门拒绝产出：%s", exc)
        return EXIT_GATE
    if args.dry_run:
        sys.stdout.write(content)
        return EXIT_OK
    output = args.output or (config_path.parent / "README.md")
    write_atomic(output, content)
    logger.info("README 已生成: %s（%d 字节）", output, len(content.encode("utf-8")))
    return EXIT_OK
