"""测试公共设施：把 profile.yaml + fixtures 拷进临时目录当工程用；tests/ 作为包被发现。"""

import shutil
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURES_DIR = REPO_ROOT / "fixtures"


@pytest.fixture()
def project(tmp_path: Path) -> Path:
    """临时工程根：含 profile.yaml 与 fixtures/。"""
    shutil.copy(REPO_ROOT / "profile.yaml", tmp_path / "profile.yaml")
    shutil.copytree(FIXTURES_DIR, tmp_path / "fixtures")
    return tmp_path
