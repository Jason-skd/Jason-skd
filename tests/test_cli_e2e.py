"""cli 端到端（fixtures 模式）：拉数→渲染→校验→写 README 全链路。"""

from pathlib import Path

from main.cli import EXIT_GATE, EXIT_OK, run


def test_fixtures_e2e_generates_readme(project: Path) -> None:
    rc = run(
        [
            "--config",
            str(project / "profile.yaml"),
            "--fixtures",
            str(project / "fixtures"),
        ]
    )
    assert rc == EXIT_OK
    readme = (project / "README.md").read_text(encoding="utf-8")
    assert readme.startswith("<!-- AUTO-GENERATED")
    # 六组件齐全且按 profile.yaml 竖排顺序（标记取各组件独有内容，
    # 打字机文案里也提到 SCNUAutoPtr，故 org 卡用头像 URL 判定）
    order = [
        "capsule-render",
        "Typing SVG",
        "Last 365 Days",
        "🧑‍💻 Languages",
        "avatars.githubusercontent.com/u/129657365",
        "Recently Working On",
    ]
    positions = [readme.index(marker) for marker in order]
    assert positions == sorted(positions)
    # v1.2：段落间 --- 分割线（六段 = 5 条）
    assert readme.count("\n\n---\n\n") == 5


def test_toggle_off_removes_component(project: Path) -> None:
    cfg = project / "profile.yaml"
    cfg.write_text(
        cfg.read_text(encoding="utf-8").replace(
            "org_card:\n  enabled: true", "org_card:\n  enabled: false"
        ),
        encoding="utf-8",
    )
    rc = run(["--config", str(cfg), "--fixtures", str(project / "fixtures")])
    assert rc == EXIT_OK
    readme = (project / "README.md").read_text(encoding="utf-8")
    assert "avatars.githubusercontent.com/u/129657365" not in readme  # org 卡已关


def test_gate_failure_keeps_old_readme(project: Path) -> None:
    sentinel = project / "README.md"
    sentinel.write_text("OLD README\n", encoding="utf-8")
    (project / "fixtures" / "components_output" / "recent_project.md").unlink()
    rc = run(
        [
            "--config",
            str(project / "profile.yaml"),
            "--fixtures",
            str(project / "fixtures"),
        ]
    )
    assert rc == EXIT_GATE
    assert sentinel.read_text(encoding="utf-8") == "OLD README\n"


def test_dry_run_writes_nothing(project: Path, capsys) -> None:
    rc = run(
        [
            "--config",
            str(project / "profile.yaml"),
            "--fixtures",
            str(project / "fixtures"),
            "--dry-run",
        ]
    )
    assert rc == EXIT_OK
    assert "capsule-render" in capsys.readouterr().out
    assert not (project / "README.md").exists()


def test_collect_degradation_surfaces_as_warning(project: Path, caplog, monkeypatch) -> None:
    """channel-2 丢仓库不能再静默：cli 必须逐仓库 WARNING 并标记降级口径。"""
    import json

    import main.sources

    fixtures = project / "fixtures" / "data"
    payloads = {
        n: json.loads((fixtures / f"{n}.json").read_text(encoding="utf-8"))
        for n in ("stats", "org", "languages", "recent")
    }
    summary = {
        "degraded": True,
        "reposScanned": 7,
        "reposSkipped": [{"repo": "Jason-skd/vassago", "reason": "clone failed x3"}],
    }
    monkeypatch.setattr(main.sources, "collect", lambda *a, **kw: (payloads, summary), raising=True)
    with caplog.at_level("WARNING", logger="main"):
        rc = run(["--config", str(project / "profile.yaml")])
    assert rc == EXIT_OK
    assert "channel-2 跳过仓库 Jason-skd/vassago" in caplog.text
    assert "降级口径" in caplog.text
