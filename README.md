# Jason-skd

这个仓库正在用 Zig 重写用于生成和更新 GitHub 个人主页 README 的工具。

## 当前状态与迁移基线

- 本仓库正在把 GitHub 主页生成流程重写为 Zig 程序。
- [`docs/zig_rewrite.md`](../zig_rewrite.md) 是已确认的 MVP 范围、目标模块边界和验收计划，但计划中的能力在对应实现与测试落地前不得描述为当前行为。
- `main` 分支是当前投入使用的 Python 实现，也是 Zig 重写的行为迁移基线。替换一项能力前，必须检查 `main` 中对应的配置、实现、测试、fixture、工作流和生成结果，明确哪些行为需要保持、哪些行为由重写计划有意删除。Python 的模块结构和实现方式不构成 Zig 架构或代码风格范例。
- `../github-stats` 是同领域的 Zig 参考实现，可用于比较 GitHub API、Git 子进程、统计聚合、资源管理和构建方式。它当前面向 Zig 0.16，且产品范围与本仓库不同，因此其 API 用法和设计不能直接移植；采用相关做法前，必须同时通过本仓库契约、`main` 行为和当前 Zig 0.17 官方源码验证。

## 常用命令

| 命令                      | 用途           |
| ------------------------- | -------------- |
| `zig build`               | 构建项目       |
| `zig build test`          | 运行测试       |
| `zig build run -- [参数]` | 构建并运行程序 |

## 文档索引

- [Zig 重写计划](docs/zig_rewrite.md)：MVP 范围、目标架构与验收标准。
- [Zig 实践缓存](docs/zig_practices.md)：当前工具链下已验证的 API、构建与依赖结论。
- [AI 治理入口](AGENTS.md)：授权、证据、工作区与交付边界。
- [AI 工作流治理](docs/governance/workflow.md)：调查、实施、提交与交付流程。
- [通用工程约束](docs/governance/engineering.md)：设计、实现、测试与完成标准。
- [本仓库治理与工程边界](docs/governance/repository.md)：特有门禁、当前状态与项目权威来源。
