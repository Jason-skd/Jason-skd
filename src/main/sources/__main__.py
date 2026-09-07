"""CLI entry for the data source layer: ``python -m main.sources``."""

from __future__ import annotations

import argparse
import sys
from typing import Any

from .http import resolve_token
from .pipeline import run


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m main.sources",
        description="Fetch GitHub profile data (issue #2) into data/*.json.",
    )
    parser.add_argument("--config", default="profile.yaml", help="profile.yaml path")
    parser.add_argument("--out-dir", default="data", help="output directory (default: data)")
    parser.add_argument(
        "--token", default=None, help="GitHub token (default: $PROFILE_PAT/$GITHUB_TOKEN)"
    )
    parser.add_argument("--from", dest="from_iso", default=None, help="pin window start (ISO 8601)")
    parser.add_argument("--to", dest="to_iso", default=None, help="pin window end (ISO 8601)")
    parser.add_argument(
        "--no-network", action="store_true", help="channels degrade instead of fetching"
    )
    parser.add_argument("--cache-dir", default=None, help="clone/scan cache dir (default: .cache)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    token = resolve_token(args.token)
    summary: dict[str, Any] = run(
        args.config,
        args.out_dir,
        token,
        no_network=args.no_network,
        from_iso=args.from_iso,
        to_iso=args.to_iso,
        cache_dir=args.cache_dir,
    )
    print(
        f"stars={summary['starsTotal']} contributions={summary['contributionsTotal']} "
        f"activeDays={summary['activeDays']} recent={summary['recentRepo']}"
    )
    print(f"languagesTop3={summary['languagesTop3']} reposScanned={summary['reposScanned']}")
    for entry in summary["reposSkipped"]:
        print(f"skipped {entry['repo']}: {entry['reason']}")
    for note in summary["notes"]:
        print(f"note: {note}")
    print(f"degraded={summary['degraded']}")
    for kind, path in summary["files"].items():
        print(f"wrote {kind}: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
