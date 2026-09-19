"""recent_project 组件：Recently Working On 卡（v1.2 视觉重做）。

锁定算法（issue #1，由数据源层执行）：从昨日（Asia/Shanghai）回溯到首个
有本人 commit 的日子，取 argmax 仓库；数据源层附带 tier 字段
（yesterday / recently，v1.2），组件不再展示具体日期。

视觉（issue #7）：大语言图标（~96px）为视觉主体、超链接挂在图标上；
仓库名在图标下方纯文本加粗（无链接色）；下方一行
「N commits yesterday|recently」。desc 不再占版面，并入图标悬停 title。
数据缺席时渲染英文占位行（校验门禁止空产出）。
"""

from __future__ import annotations

from typing import Any

from main.components._icons import icon_url

DEFAULT_HEADER = "🚀 Recently Working On"
DEFAULT_ICON_HEIGHT = 96
_PLACEHOLDER = "No commits to show in the last year"


def render(config: dict[str, Any], data: dict[str, Any]) -> str:
    """渲染最近项目块；data = data/recent.json。"""
    header = str(config.get("header") or DEFAULT_HEADER)
    icon_height = int(config.get("icon_height", DEFAULT_ICON_HEIGHT))
    repo = str(data.get("repo") or "").strip()
    if not repo:
        return "\n".join(
            [
                f'<h3 align="center">{header}</h3>',
                "",
                f'<p align="center"><sub>{_PLACEHOLDER}</sub></p>',
            ]
        )

    url = str(data["url"]).strip()
    if not url:
        raise ValueError(f"recent 数据缺少 url（repo={repo!r}）")
    desc = str(data.get("desc") or "").strip()
    lang = str(data.get("lang") or "").strip()
    commits = int(data.get("commits") or 0)
    tier = str(data.get("tier") or "recently").strip()

    overrides = dict(config.get("icons") or {})
    icon_src = icon_url(lang, overrides) if lang else None
    hover = f"{repo} — {desc}" if desc else repo

    lines = [f'<h3 align="center">{header}</h3>', "", '<p align="center">']
    if icon_src:
        # 链接语义在大图标上；仓库名退为纯文本加粗
        lines.append(
            f'  <a href="{url}"><img src="{icon_src}" height="{icon_height}"'
            f' alt="{lang}" title="{hover}" /></a>'
        )
        lines.append(f"  <br/><b>{repo}</b>")
    else:
        # 无图标语言回落：链接挂回仓库名（保持可达性）
        lines.append(f'  <a href="{url}"><b>{repo}</b></a>')
    if commits:
        lines.append(f"  <br/><sub>{commits} commits {tier}</sub>")
    lines.append("</p>")

    return "\n".join(lines)
