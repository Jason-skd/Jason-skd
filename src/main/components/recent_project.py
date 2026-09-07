"""recent_project 组件：最近在写的仓库卡。

锁定算法（issue #1，由数据源层执行）：从昨日（Asia/Shanghai）回溯到首个
有本人 commit 的日子，取 argmax 仓库；组件只渲染 data/recent.json。
数据缺席时渲染占位行（校验门禁止空产出）。
"""

from __future__ import annotations

from typing import Any

from main.components._icons import icon_url

DEFAULT_HEADER = "🔥 最近在写"


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染最近项目块；data = data/recent.json。"""
    header = str(config.get("header") or DEFAULT_HEADER)
    repo = str(data.get("repo") or "").strip()
    if not repo:
        return "\n".join(
            [
                f'<h3 align="left">{header}</h3>',
                "",
                "<p><sub>（近一年暂无可展示的本地提交）</sub></p>",
            ]
        )

    url = str(data["url"]).strip()
    if not url:
        raise ValueError(f"recent 数据缺少 url（repo={repo!r}）")
    desc = str(data.get("desc") or "").strip()
    lang = str(data.get("lang") or "").strip()
    commits = int(data.get("commits") or 0)
    date = str(data.get("date") or "").strip()

    overrides = dict(config.get("icons") or {})
    icon_url_value = icon_url(lang, overrides) if lang else None
    icon = (
        f'<img src="{icon_url_value}" height="20" alt="{lang}" /> '
        if icon_url_value
        else ""
    )

    title = f'  <a href="{url}"><b>{repo}</b></a>'
    if desc:
        title += f"\n  — {desc}"

    meta_parts = [
        part for part in (f"{icon}{lang}" if lang else "", _meta(commits, date)) if part
    ]
    meta = f"  <br/>{' · '.join(meta_parts)}" if meta_parts else ""

    return "\n".join(
        [f'<h3 align="left">{header}</h3>', "", "<p>", title, meta, "</p>"]
    )


def _meta(commits: int, date: str) -> str:
    if date and commits:
        return f"{date} 当天 {commits} commits"
    if commits:
        return f"{commits} commits"
    return date
