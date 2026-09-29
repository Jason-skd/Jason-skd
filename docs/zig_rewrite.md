# Zig 重写主页计划

> 定稿时间：2026-09-19
>
> 本文前半部分记录迁移时 Python 主页的功能边界、Zig 生态调查结论和 MVP 范围。
> 当前生产实现为 Zig；生成器说明保留在 [`generator.md`](generator.md)，不会嵌入个人主页 README。
> 后续实现以本文为范围依据；超出 MVP 的功能在出现真实需求后再讨论。

## 一、结论

主页可以使用 Zig 重写，MVP 不需要创建或维护任何额外的独立仓库。

所有逻辑都先保留在本仓库中，但必须按职责严格拆分为内部模块。模块之间通过明确的数据类型和窄接口协作，业务聚合层不能直接承担 HTTP、子进程、文件写入或语言识别等基础职责。只有未来出现第二个真实消费者时，才重新评估将某个内部模块发布为独立库。

锁定的技术选择如下：

| 能力               | 选择                                                |
| ------------------ | --------------------------------------------------- |
| Zig 版本           | 当前项目锁定的 Zig 0.17 开发版本                    |
| 参数解析           | `zig-clap`                                          |
| YAML 解析          | `ymlz`                                              |
| HTTP               | `std.http`                                          |
| JSON               | `std.json`                                          |
| GraphQL            | `std.http` POST + `std.json`，不引入 GraphQL 专用库 |
| Git                | 调用系统 `git` CLI                                  |
| Markdown/HTML 输出 | 标准库 Writer 和格式化 API                          |
| 模板引擎           | 不使用                                              |
| 时区               | MVP 将 `Asia/Shanghai` 按固定 UTC+8 处理            |

依赖在接入时必须由当前锁定的 Zig 0.17 编译器实际构建和测试。兼容性验证属于实施工作，不再重新开启选型讨论。

## 二、现有主页的功能边界

迁移前的 Python 主页不是简单的“请求 GitHub 后拼 README”，而是由以下功能组成。

### CLI 与配置

- 解析配置文件、输出路径、fixture 和 dry-run 等参数。
- 从 `PROFILE_PAT` 或 `GITHUB_TOKEN` 获取凭据。
- 读取 `profile.yaml`，校验字段并提供默认值。
- 按配置决定 section 的启用状态和输出顺序。

### GitHub 数据

- 通过 GraphQL 获取账户、贡献、私有贡献、仓库及外部贡献信息。
- 通过 REST 获取组织和仓库补充信息。
- 处理认证、重试、HTTP 错误、GraphQL `errors` 和 token 脱敏。

Python 版没有使用 GraphQL 客户端库。它通过 `requests` 手写 HTTP POST，提交 `query` 和 `variables`，再手动读取 JSON 字段。Zig 版继续采用相同的薄实现思路。

### Git 活动与语言统计

- 克隆或读取仓库。
- 按时间窗和作者邮箱筛选提交。
- 从 `git log --numstat` 获取提交日期及文件增删行数。
- 根据文件名或扩展名识别语言并聚合权重。
- 选择最近活跃项目。

### 组件与输出

- 渲染 banner、typing、stats、languages、org card 和 recent project。
- 校验所有启用组件均成功生成非空内容。
- 按顺序拼接 Markdown/HTML。
- 原子替换 README，失败时保留旧文件。

### 自动化

- 由 GitHub Actions 定时、手动或在源文件变更时运行。
- 成功生成后提交 README；失败时不提交半成品。

## 三、MVP 范围

### 保留

- YAML 驱动的主页内容和组件顺序。
- GitHub REST 与 GraphQL 数据获取。
- PAT 访问私有 GitHub 数据。
- 基于系统 `git` 的必要活动统计。
- 基于精简语言目录的语言识别和聚合。
- 当前主页的六个 section。
- fixture/offline 测试能力。
- dry-run。
- 完整性校验门。
- README 原子写入。
- secret-safe 日志和子进程错误。
- GitHub Actions 自动更新。

### 有意缩减

Git 活动模块只实现主页实际需要的最小集合。MVP 不提前复刻 Python 版的全部 clone、refresh、降级和缓存策略，具体以主页所需数据字段为边界。

语言识别只实现：

- 特殊文件名到语言的映射；
- 文件扩展名到语言的映射；
- 语言到 `programming` 等类型的映射；
- 按 `languages.types` 白名单统计（默认 `programming` 和 `markup`）；
- 多仓库语言权重聚合。

### 排除规则与 Python 口径

支持原 YAML 的 `excludes` 配置块，包括：

```yaml
excludes:
  repos: []
  languages: [Groovy]
  paths:
    - "**/vendor/**"
    - "**/vendors/**"
    - "**/third_party/**"
    - "**/thirdparty/**"
    - "**/third-party/**"
    - "**/extern/**"
    - "**/external/**"
    - "**/deps/**"
    - "**/zig-pkg/**"
```

仓库名按完整 `owner/name` 或裸名称、不区分 ASCII 大小写精确匹配；
仓库排除同时作用于扫描和最近项目候选，不改变账号 stars/contributions。
语言排除按名称精确匹配，优先于 `languages.types`。路径规则与 Python
`fnmatch` 口径一致，支持 `*`、`?`、字符集合和否定集合；无 `/` 的规则
匹配 basename，`**/` 前缀同时匹配仓库根目录。路径比较区分大小写。
省略 `paths` 使用八个通用 vendor 类默认规则；显式列表整体替换默认值，
`paths: []` 清空默认路径排除。生产配置额外排除 `zig-pkg` 中的 vendored SQLite。
各仓库根 `.gitattributes` 中以 `linguist-vendored` 或 `linguist-generated`
开头的属性条目也加入路径排除，保持 Python 的简化语义，不实现完整属性解释器。
路径排除只影响语言权重，不删除提交，也不改变最近项目的提交数。

### 明确不做

- GitHub Linguist 的 shebang、modeline、内容启发式和完整歧义判断；
- 通用模板语言；
- 通用 GraphQL 客户端；
- 通用缓存库；
- 任何新的独立仓库。

配置使用 `excludes`，不接受拼写错误和旧别名 `exclude`。排除列表支持 block
语法及单行 flow 列表；未知子键、重复键和非法类型在 typed binding 前报错。

## 四、内部模块设计

下列名称是职责名称；实施时可以按 Zig 命名惯例调整文件名，但不得将职责重新混入 `main.zig` 或单个大型模块。

### `cli`

负责：

- 使用 `zig-clap` 声明和解析参数；
- 将参数转换成应用层输入；
- 映射最终退出状态。

不负责配置解析、网络请求或业务聚合。

### `config`

负责：

- 使用 `ymlz` 将 YAML 绑定到明确的 Zig struct；
- 校验必需字段、section 名称、重复 section 和数值范围；
- 提供 MVP 默认值；
- 校验并归一化 `excludes`，区分省略列表与显式空列表。

### `github`

负责：

- `std.http` client 生命周期；
- REST GET 与 GraphQL POST；
- Authorization、Accept、API version 和 User-Agent 请求头；
- retry/backoff 和 HTTP 状态处理；
- rate-limit 信息；
- token 脱敏；
- 可注入 transport 或等价测试边界。

GraphQL helper 只负责序列化 `{query, variables}` 和解析 `{data, errors}`，不解析 GraphQL 语法，也不实现动态 query builder。

### `github_workflow`

负责 Profile、Organization 和 Repository metadata 的 GitHub 数据采集流程，声明内部 API response 类型和主页所需的 owned Domain 类型。它只依赖公开 `github` client，不直接操作底层 HTTP client；viewer fallback、owned repository 分页和 response 到 Domain 的转换属于这一层，跨数据源降级仍由 `pipeline` 决定。

### `json`

使用 `std.json` 直接绑定 Zig struct，不开发新的 JSON parser。

统一策略为：

- API 响应忽略未知字段，允许 GitHub 增加无关字段；
- 主页实际依赖的字段保持必需，缺失即报错；
- API 允许为 `null` 的字段使用 `?T = null`；
- 重复字段保持标准库默认的错误行为；
- 用一个薄内部 helper 统一 allocator 生命周期、解析选项和错误上下文；
- GraphQL `errors` 即使与 `data` 同时出现也必须显式处理，不能静默丢弃。

### `process`

负责 secret-safe 子进程调用：

- 使用 argv，而不是拼接 shell 命令；
- 禁止交互式凭据提示；
- 捕获退出状态、stdout 和 stderr；
- 设置超时或上层可控的取消边界；
- 所有错误在离开模块前清理 token 和含凭据 URL；
- 清理临时目录和敏感数据。

### `git_activity`

负责：

- 通过 `process` 调用系统 `git`；
- 获取 MVP 必需的仓库内容和提交记录；
- 按作者邮箱和时间窗筛选；
- 解析必要的 `git log`/`numstat` 输出；
- 返回结构化活动数据。

clone 优先使用 shallow-since，Git 拒绝该窗口时回退到 depth 200、再到完整
clone，均保留所有分支。`git log` 先按作者邮箱固定字符串过滤，再在 parser
中精确校验邮箱及时间；partial clone 的后续日志和属性读取继续携带认证。
生产日志记录逐仓库扫描结果与稳定失败类别；失败仓库不再无诊断地漏算。

MVP 不实现 refs fingerprint、stale-cache 回退或扫描结果 JSON 缓存。仓库和临时目录只服务于单次运行，并由该模块或调用方明确清理。未来发现真实性能问题后，再为此模块设计专用缓存，不抽象成通用缓存库。

### `language_catalog` 与 `language_stats`

这两个模块共同承担此前讨论中的 “Linguist-lite” 职责。`Linguist-lite` 只是描述，不是要创建或兼容一个名为 Linguist-lite 的外部项目。

`language_catalog` 负责：

- 内嵌由 GitHub Linguist `languages.yml` 精简生成的数据快照；
- 特殊文件名和扩展名到语言的映射；
- 语言类型查询；
- 少量明确记录的歧义扩展名裁定。

`language_stats` 负责：

- 接收 Git 活动模块提供的文件权重；
- 应用仓库、路径、语言排除和类型白名单；
- 聚合、排序和计算百分比。

快照在运行时不联网更新。更新快照是显式的维护操作，生成脚本和快照元数据应记录上游来源；MVP 不要求生成脚本本身使用 Zig。

### `clock`

负责 Unix 时间、UTC API 时间范围、自然日分桶和格式化。MVP 中唯一支持的主页时区是 `Asia/Shanghai`，实现为固定 UTC+8。

当前 Zig 0.17 的 `std.Tz` 能解析 TZif，但不自带通过 `Asia/Shanghai` 名称直接查询的跨平台 IANA 数据库。当前主页不需要为这一点引入 tzdata。未来需要任意 IANA 时区或夏令时时，再扩展该模块。

### `components` 与 `assemble`

语言统计与渲染 payload 使用 `percentage_tenths: u16` 表示十分之一百分点
（352 即 35.2%）。分母是过滤后全部语言权重，不因 Top N 截取而重新归一。
按 Python 顺序先保留两位小数，再格式化到一位小数；独立舍入可能使合计
不等于 100.0%。组件只显示结果，不重新计算占比。

时间窗口由应用 pipeline 使用 `config.window_days` 统一确定，并用于 Git/GitHub
采集及 payload 构建。生产配置为 365 天；不得采集较短窗口却标注较长范围。
近期项目从昨天开始按 UTC+8 自然日选择，在采集窗口内最多回溯 60 天，与
Python 基线一致。首个活跃日按提交数、仓库在整个采集窗口内的最新提交时间、
仓库名升序打破并列。GitHub 缺少主语言时，回退到该仓库经过路径过滤后的
提交语言权重。空状态保留 Python 文案 `No commits to show in the last year`。
stats 与 recent-project payload 均携带采集窗口；stats 默认标题随窗口变化，
显式自定义标题保持原样。stats 脚注仍显示 `Last N days ·`。

- 每个 section 使用标准库 Writer 输出 Markdown/HTML；
- component 只接收自己的配置切片和数据类型；
- `assemble` 负责顺序、启用状态、非空校验和 section 间分隔；
- 不引入 Jinja、ZTT、zig-pek 或自制占位模板语言；
- URL/query percent-encoding 由独立的小 helper 处理，不能靠字符串替换凑出。

typing 组件在 MVP 直接使用配置宽度，不复刻 Python `unicodedata` 的显示宽度估算。

### `atomic_output`

负责：

- 在目标文件所在目录创建临时文件；
- 完整写入并刷新；
- 成功后原子替换目标文件；
- 任意失败时清理临时文件并保留旧 README。

### `pipeline`

只负责编排：

1. 加载配置；
2. 获取 GitHub 数据；
3. 获取必要的 Git 活动；
4. 聚合主页 payload；
5. 渲染并校验全部 section；
6. dry-run 输出或原子写入 README。

它不能包含 HTTP 请求细节、子进程实现、JSON 字段遍历或 Markdown 组件正文。

## 五、数据流

```text
CLI + environment
        |
        v
typed config ---------> GitHub workflow ----> GitHub client ----> REST / GraphQL
        |                      |
        |                      v
        |               owned Domain values
        |
        +---------------> Git activity ------> system git
                               |
                               v
                    language catalog/stats
                               |
                               v
                         page payloads
                               |
                               v
                     components + assemble
                               |
                     +---------+---------+
                     |                   |
                  stdout            atomic README
```

GitHub client、Git 活动、语言统计和渲染之间不得交换无约束的通用 JSON tree。模块边界使用明确的 Zig struct，使字段缺失和类型变化尽可能在边界处失败。

## 六、Python 版缓存的处理

Python 版存在两类运行缓存：

- `.cache/repos/` 保存克隆的仓库；
- `.cache/scan_cache.json` 保存每个仓库的 refs fingerprint、时间窗口、过滤配置 hash、每日提交数、语言权重、最近提交时间和提交总数。

它可以在输入未变化时跳过 `git log` 重扫，也可以在网络刷新失败且 refs 未变化时使用旧扫描结果。但当前 GitHub Actions 没有持久化 `.cache`，跨任务收益有限。

MVP 不迁移这套缓存：

- 不实现 `scan_cache.json`；
- 不实现 refs fingerprint；
- 不实现 stale-cache 降级；
- 不建立通用缓存抽象。

如果后续测量确认 Git 扫描是瓶颈，再在 `git_activity` 内加入面向该领域的缓存。

## 七、实现约束与验收

### 构建与依赖

- `zig-clap` 和 `ymlz` 必须由项目锁定的 Zig 0.17 编译器成功构建。
- 依赖 URL、内容 hash 和 Zig 版本一同锁定。
- 除 `zig-clap`、`ymlz` 外，MVP 不增加第三方运行依赖。

### 测试边界

- 配置正常值、默认值、未知 section、重复 section、`excludes` 覆盖和显式空列表。
- JSON 正常响应、未知字段、缺失必需字段、`null`、类型错误和 GraphQL `errors`。
- HTTP 成功、认证失败、限流、可重试错误和 token 脱敏。
- Git 命令失败、超时、二进制文件、重命名路径和作者/时间窗筛选。
- 语言文件名/末段扩展名映射、类型白名单、路径/属性排除、权重及 Top N 百分比。
- 每个 section 的 fixture 输出和完整页面 fixture。
- 任一 section 失败时不改写 README。
- 原子输出成功、失败清理和旧文件保留。
- dry-run 不写文件。

### 完成标准

- 六个现有 section 均由 Zig 生成。
- 公共及私有 GitHub 数据均可按 MVP 口径获取。
- 生成失败不会留下半成品或泄露 token。
- fixture/offline 测试不访问网络或真实仓库。
- GitHub Actions 使用 Zig 构建并更新 README。
- 生产分支不保留 Python 运行时代码、Python 依赖和旧工作流。
- `zig build test` 和端到端 fixture 测试通过。
- 模块结构符合本文边界，核心逻辑没有堆积在 `main.zig`。

## 八、延后事项

以下内容只有出现真实需求后才重新讨论：

- 将内部模块拆成独立仓库或公共 Zig 包；
- 任意 IANA 时区和夏令时；
- 完整 GitHub Linguist 兼容；
- Git 扫描缓存和离线 stale-cache；
- 通用 GraphQL client 或 query builder；
- 通用模板引擎；
- 更复杂的 Unicode 显示宽度估算；
- Python 版中未被 MVP 页面实际使用的 Git 活动统计和降级路径。

## 已实现的渲染边界（Issue #18）

`src/render.zig` 提供六个独立的 Writer 渲染函数，仅借用对应配置、主题和
已完成的 typed payload；不采集数据，也不执行网络、子进程或文件系统 I/O。
语言占比按 `percentage_tenths` 展示一位小数，不在渲染层再次截取 Top-N 或重算比例。
统计脚注与最近项目空状态均从 payload 获取实际窗口天数。

组件 fixture 在迁移时对照旧 Python golden，保留居中布局、图标、回退链接、
悬停描述与英文文案。HTML 属性中的查询分隔符使用 `&amp;`，查询值中的空格
使用 `%20`；这是转义表示变化，不改变 URL 或可见布局。统计脚注恢复生产
口径 `Last N days · incl. X private contributions`。文字与属性均做 HTML
转义，完整 URL 不重复百分号编码，单个查询值通过标准库 URI component 编码。
组件自身传播 `WriteFailed`，调用者不能使用失败后 Writer 中残留的前缀。

`src/render_page.zig` 的 `assemble(allocator, config, page)` 返回调用者负责
释放的完整 Markdown。它按 `sections` 顺序调用 renderer，跳过禁用的组织卡
和最近项目；重复 section、无有效 section、缺失 payload、无内容和组件失败
均返回错误。未知名称由配置解析拒绝，穷尽的 `Section` switch 保证每个合法
名称都有 renderer。组装还检查启用的统计/最近项目窗口与配置一致。
中间缓冲区在任何失败路径释放，成功后才转交完整页面；README 文件替换、
数据源查询窗口和 CLI 接线仍由 Issue #16 的应用编排负责。

验证包括六组件 golden、整页 golden、重排/禁用、错误传播、分配失败穷举，
以及配置解析 → payload → 页面串联的 90 天/一位小数检查。整页 fixture
来源于独立的组件期望与原模板结构，并非由待测渲染器生成。

视觉验证范围：本地无界面 Chrome 对整页 golden 的浅色/深色 HTML 预览检查
确认了主体布局、徽章、语言图标、组织卡、最近项目和页脚；打字 SVG 在静态
截图中为空，动画播放和 GitHub 在线渲染效果尚未验证。外部 SVG 服务的加载
不属于离线测试保证。

## 已实现：Issue #16 应用流水线与输出

`src/root.zig` 解析 CLI，并在最终边界输出固定类别诊断和退出码：
成功（含 help）为 0，应用或输出失败为 1，参数错误为 2。
诊断不回显 argv、文件路径、HTTP 响应体或凭据。
`src/main.zig` 只转交启动上下文和返回退出码。

`application.generate` 读取配置，使用启动时唯一的 Unix 秒时间，按
`[now_utc - window_days * 86400, now_utc]` 构造 GitHub/Git 的闭区间。
生产 adapter 复用 GitHub workflow 和 Git activity，合并并去重自有、配置的
组织仓库，以及启用 `include_external` 时的贡献仓库；外部贡献仓库查询上限为
100。Git 命令超时为 120 秒，临时 clone 使用 `TMPDIR`（未设置时 `/tmp`）。
应用继续调用语言统计、`page_payload.build` 和 `render_page.assemble`，所有
section 成功后才交付输出。必需 Profile 或凭据失败会终止；单仓库活动失败
保留为结构化 unavailable 结果。缺失组织仅在启用 org_card 时使 payload
失败；可选仓库 metadata 缺失允许使用已有 Profile metadata 或空值。

入口传给 `output.deliver` 的默认目标是 `README.md`，`--output` 可以覆盖。
`--dry-run` 把完整页面写到 stdout，不打开目标文件。
正常模式在目标父目录创建 atomic 临时文件，完成 Writer flush 和 File sync
后调用 Atomic.replace；defer 在失败、取消和成功路径释放临时资源。
父目录必须已经存在，目标必须为文件路径。该行为提供完整文件的原子可见性，
未增加父目录 fsync 或跨平台断电恢复协议；清理受文件系统可用性约束。

### 当前 Zig fixture 契约

`--fixtures DIR` 读取 `DIR/data.json`（上限 16 MiB）；配置仍由 `--config`
指定（上限 1 MiB）。这是 typed source-domain snapshot，不兼容旧 Python
最终渲染数据目录。结构定义在 `application_fixture.Snapshot` 和
`application_input.Data`：

- `now_utc`：固定 Unix 秒，覆盖生产启动时间；必须足以形成配置时间窗口；
- `data`：包含 `github_workflow.Profile`、可选 Organization、RepositoryMetadata
  列表和 `git_activity.Aggregate`；为 null 表示必需 Profile 获取失败；
- activity 包含已按配置作者和上述时间区间过滤的 commit/file-change 数据；
  计数与列表应一致，unavailable 仓库的 commits 必须为空；
- JSON 严格匹配领域类型，拒绝未知字段；完整示例位于
  `tests/fixtures/application/success/data.json`，六个 section 的配置位于相邻
  `profile.yaml`。

fixture 分支不初始化 HTTP client、不执行 Git、不访问 snapshot 中的仓库路径；
仍执行语言统计、payload 和 render。`local-failure` 样例验证局部仓库失败仍可
生成页面；`missing` 验证必需数据失败；`empty` 在启用 languages 时沿用
`MissingLanguages` 渲染失败契约，未启用 languages 时允许空活动页面。

```sh
zig build run -- --config tests/fixtures/application/profile.yaml --fixtures tests/fixtures/application/success --dry-run
zig build run -- --config tests/fixtures/application/profile.yaml --fixtures tests/fixtures/application/success --output /tmp/profile-preview.md
zig build test-unit
zig build test-cli
zig build test
```

测试包含同目录替换、flush/sync/rename/取消故障注入、临时文件清理、旧内容
保持、fixture 的网络/进程禁用、可选数据边界、分配失败清理，以及 CLI stdout、
stderr、退出码和文件状态。生产 GitHub 服务未作为离线测试的依赖。

## 已实现：Issue #12 Zig CI 入口

`.github/workflows/update.yml` 使用 `mlugg/setup-zig@v2` 安装固定发行包
`0.17.0-dev.2307+392b17125`，并显式检查 `zig version`。CI 使用可下载的
0.17 nightly，不跟随浮动 `master`，也不在 runner 上从源码编译 Zig。
`build.zig.zon` 的 minimum 仍表示最低版本，CI 的完整版本另由 workflow 锁定。

执行顺序为 `zig build` → `zig build test` → 生成 → 提交。保留每日
`17 16 * * *` UTC、手动 dispatch、`refactor/zig` 源文件 push 和按 ref 串行运行；
push paths 覆盖 workflow、构建与依赖 manifest、配置、src、tests、tools。
任一步失败后，默认 success 条件阻止后续生成或提交步骤继续执行。

手动运行勾选 `fixtures` 时使用 `tests/fixtures/application/profile.yaml`
与 `tests/fixtures/application/success`，生成阶段不注入 secret、不访问
外部数据；checkout、工具链安装和依赖下载仍需要网络。未勾选时使用根
`profile.yaml`，仅真实生成步骤注入 `PROFILE_PAT` 与 `GITHUB_TOKEN`。
不要增加回显环境变量、请求头或响应体的调试命令。

两种模式都将 README 写到选择的 ref，并可能在该分支产生自动提交。
提交阶段仅暂存 `README.md`；内容相同时成功退出，不创建空提交。
内容变化时沿用 bot 身份与 `chore(readme): auto update YYYY-MM-DD [skip ci]`
格式。fixture dispatch 应选择验收分支，以免将演示页面写到主页分支。
默认分支为 `refactor/zig`，它是唯一生产生成路径；`feat/python` 仅保留退役
实现供历史查阅，不再用于生产生成。Zig 分支不含 Python 源码、依赖锁、
解释器版本文件或 Python 调用。运行说明与文档索引位于
[`generator.md`](generator.md)，不进入生成的主页；不要手工修改生成后的 README。

### 2026-09-27 验收记录

- GitHub Actions run `36307821518`：固定 2307 编译器完成构建、测试和
  fixture 生成；日志为 `README already up to date.`，分支 HEAD 保持
  `3082e4c1f213fd21f08682b6775f8953ef593165`，未产生提交。
- run `36307855918`：真实生成成功，banner、typing、stats、languages、
  org_card、recent_project 均存在；bot 提交 `0f63722` 仅修改 README。
  日志中两个 secret 均为掩码，未发现可识别的未掩码 GitHub token。
- run `36304244821`：修复前生成失败，commit/push 步骤确实 skipped。
  build/test 的失败门禁通过 workflow 顺序与默认 success 条件检查；
  未向远端提交故意破坏构建或测试的代码。
- 本地 2326 编译器：`zig build`、`zig build test --summary all`
  （160/160）、修改源码的 `zig fmt --check` 和 `git diff --check` 通过；
  `actionlint` 1.7.7 通过。认证回环回归在旧实现上失败，在修复后通过；
  真实数据 dry-run 成功。
