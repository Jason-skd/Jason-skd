"""Atomic JSON emission for data/*.json."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


def write_json(out_dir: Path, name: str, payload: dict[str, Any]) -> Path:
    """Write ``out_dir/name`` atomically with stable formatting."""
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / name
    tmp = target.with_suffix(target.suffix + ".tmp")
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, target)
    return target
