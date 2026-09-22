# Zig 实践缓存

本文缓存已经通过当前工具链源码和实际构建验证的 Zig 实践，减少后续任务重复调查。它不是独立规范，也不能替代当前 revision 的源码：结论超出记录范围、工具链 revision 变化或实际行为冲突时，必须重新读取源码。

## 验证基线

- 编译器：`../zig/build/stage3/bin/zig`
- 版本：`0.17.0-dev.2248+3f6a02acd`
- Zig 源码 revision：`3f6a02acdda41190eab7d57a9f037df9d4853631`
- 项目验证入口：`zig fmt --check`、`zig build`、`zig build test` 和 `zig build run --`

后续任务必须先核对编译器版本和源码 revision。只有两者一致且改动完全落在本文已覆盖的 API 与语义内时，本文才能作为调查索引；仍应打开列出的源码符号确认上下文。

## 私有应用模块与进程入口

适用范围：本仓库的单一可执行程序及其内部应用逻辑。

- 使用 `b.createModule` 创建包内私有应用模块。只有需要让其他 Zig 包通过 `dependency.module(name)` 使用的公共模块才使用 `b.addModule`。
- `src/main.zig` 保留 Zig 进程入口 `main(init: std.process.Init) !void`，只负责把进程上下文交给应用入口；业务和领域逻辑不得重新混入 `main.zig`。
- `src/root.zig` 是私有应用模块的根、应用编排入口和测试聚合入口。它不是操作系统调用的进程入口。
- `std.process.Init` 由启动代码构造并在进程退出时统一清理。应用可以在顶层编排期间借用其中的 `arena`、`gpa`、`io`、参数和环境；不得自行销毁这些资源。领域模块应继续接收更窄的值或能力，而不是依赖完整的 `Init`。

关键源码：

- `../zig/lib/std/Build.zig`：`addModule`、`createModule`
- `../zig/lib/std/Build/Module.zig`：`CreateOptions.imports`、`Import`
- `../zig/lib/std/process.zig`：`Init`、`Init.Minimal`
- `../zig/lib/std/start.zig`：`callMain`、`wrapMain`
- `../zig/lib/init/build.zig`：官方生成项目的库模块与可执行模块拆分
- `../zig/lib/init/src/main.zig`：当前 `main(std.process.Init)` 示例

## Build、Run 与 Test 图

适用范围：`build.zig` 中的标准构建步骤。

- 可执行模块通过 `.imports` 获得私有应用模块；应用模块通过自己的 `.imports` 获得第三方依赖。import table 明确了每个模块可见的依赖，不能依赖隐式全局导入。
- `b.installArtifact(executable)` 定义默认安装产物。
- `b.addRunArtifact(executable)` 创建运行步骤；让它依赖 `b.getInstallStep()`，并用 `addPassthruArgs()` 支持 `zig build run -- ...`。
- `b.addTest` 只构建测试可执行文件，不会执行测试；必须再用 `b.addRunArtifact(tests)` 并让顶层 `test` step 依赖该运行步骤。
- 当前 `main.zig` 没有独立行为，测试根直接使用应用模块。以后如果进程 adapter 获得自身逻辑，再为可执行根增加对应测试，不提前保留空测试目标。

关键源码：

- `../zig/lib/std/Build.zig`：`addTest`、`addRunArtifact`、`dependency`、`Dependency.module`
- `../zig/lib/std/Build/Module.zig`：`Module.init` 对 import table 的构造
- `../zig/lib/std/Build/Step/Run.zig`：`addPassthruArgs`
- `../zig/lib/init/build.zig`：官方 run、install 和 test step 组合

## 测试聚合

模块根使用匿名测试块显式导入测试文件：

```zig
test {
    _ = @import("dependency_validation.zig");
}
```

这是当前标准库用于聚合子模块测试的常见形式，可在 `std/json.zig`、`std/fs.zig`、`std/Random.zig` 和 `std/Io/Threaded.zig` 等文件中找到。新增模块的测试应由最近的模块根纳入，而不是依靠未被引用的文件自动发现；若实现与测试拆在不同文件，由实现模块的匿名测试块导入自己的测试文件，上层根只导入实现模块，避免上层知道下层测试布局。

## Unix 秒到固定 UTC DateTime

适用范围：把非负 Unix 秒格式化为只含四位年份和整秒的 UTC `YYYY-MM-DDTHH:MM:SSZ` 文本，例如 GitHub GraphQL `DateTime` 变量；不适用于负时间戳、时区转换、闰秒或带小数秒的格式。

- 当前 `std.time.epoch` 提供从 `EpochSeconds` 到年、月、日和日内时分秒的 UTC 拆分，但没有公开的 RFC 3339 formatter。先在领域边界拒绝负时间戳，并按目标协议限制最大年份，再构造 `EpochSeconds`。
- 四位年份、整秒和尾随 `Z` 的结果恒为 20 字节。使用 `[20]u8` 与 `std.mem.print` 可以无分配地生成结果；`std.fmt.bufPrint` 在当前 revision 已标记为 deprecated。
- `MonthAndDay.day_index` 从 0 开始，输出日期时必须加 1；`Month.numeric()` 已返回从 1 开始的月份。

```zig
const seconds: std.time.epoch.EpochSeconds = .{ .secs = timestamp };
const year_day = seconds.getEpochDay().calculateYearDay();
const month_day = year_day.calculateMonthDay();
const clock = seconds.getDaySeconds();
var buffer: [20]u8 = undefined;
_ = std.mem.print(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
    year_day.year,
    month_day.month.numeric(),
    month_day.day_index + 1,
    clock.getHoursIntoDay(),
    clock.getMinutesIntoHour(),
    clock.getSecondsIntoMinute(),
}) catch unreachable;
```

关键源码：

- `../zig/lib/std/time/epoch.zig`：`EpochSeconds.getEpochDay`、`EpochSeconds.getDaySeconds`、`EpochDay.calculateYearDay`、`YearAndDay.calculateMonthDay`、`Month.numeric` 及 `epoch decoding` 测试
- `../zig/lib/std/mem.zig`：`PrintError`、`print` 及其固定缓冲测试
- `../zig/lib/std/fmt.zig`：已弃用的 `bufPrint` 转发入口

验证基线为 Zig `0.17.0-dev.2248+3f6a02acd`、源码 revision `3f6a02acdda41190eab7d57a9f037df9d4853631`。GitHub profile 数据源测试覆盖 Unix epoch、闰日和四位年份上界 `9999-12-31T23:59:59Z`。若标准库加入正式 DateTime/RFC 3339 formatter、epoch 类型开始支持负值，或目标协议的精度与年份范围改变，应重新评估此写法。

## 有界子进程与敏感缓冲区

适用范围：需要捕获输出、继承或覆盖环境并可能处理凭据的内部子进程 adapter。

- `std.process.run` 使用 argv 直接启动进程，把 stdin 设为 `ignore`，通过 `Io.File.MultiReader` 同时读取 stdout 和 stderr，并以 `defer child.kill(io)` 覆盖 timeout、取消、输出超限和读取失败后的终止与等待。`ignore` 会把流接到 POSIX `/dev/null` 或 Windows `NUL`，不同于可能令子进程遇到 `EBADF` 的 `close`；`Child.kill` 在 `wait` 后幂等且不可取消，因此同一条 defer 同时适合正常和异常清理。正常返回的 `Child.Term` 保留非零退出、signal、stopped 和 unknown；调用方不应把这些结构化结束状态折叠为 spawn 错误。
- `process.run` 的读取循环会把同一个 `RunOptions.timeout` 传给每次 `MultiReader.fill`。`Io.Timeout.duration` 在每次等待时都表示一段新的相对时长，因此要求整条命令共享总时限时，应在进入 `process.run` 前调用 `timeout.toDeadline(io)` 一次，将其固定为 absolute deadline。`error.Timeout` 和 `error.Canceled` 保持在 `process.RunError` 中，不转换为退出状态。
- `Io.Future.cancel` 请求任务在下一个可取消 I/O 点收到 `error.Canceled`，并等待任务返回其原始结果类型；它不是跳过函数清理的强制线程终止。取消测试应先等待子任务报告“已经启动”，再调用 `cancel` 并断言 `error.Canceled`，避免用固定时长猜测竞态是否发生。
- `process.Environ.Map` 独立拥有每个键和值。`put` 和 `putMove` 会断言键合法，覆盖值和 `deinit` 都会直接释放内存；敏感环境 adapter 应先用 `validateKeyForPut` 和 NUL 检查返回普通错误，再复制数据。覆盖前清零旧值，失败路径与最终销毁前清零全部值，避免把调用方 map 的所有权或可变性带入子进程层。
- `Uri.parse` 返回借用输入的 component；对解析成功且带 userinfo 的 HTTP(S) URL，可用 `Uri.writeToStream` 并关闭 `Format.Flags.authentication` 重新格式化。authority 明确含 `@` 但解析失败的候选 URL 应整体替换，避免 malformed credential 逃逸。之后再按长度降序替换非空显式 secret，防止较短前缀先替换而保留较长 secret 的尾部。
- `crypto.secureZero` 通过 volatile slice 防止清零被优化掉。当前 `Allocator.free` 会先把 slice 写成 `undefined`，再调用 allocator vtable 的 `free`；因此 `secureZero(bytes); gpa.free(bytes)` 不能保证清零是释放前的最后一次写入。对已知由同一 allocator 以自然对齐 `[]u8` 分配的非空 slice，应在清零后以原对齐直接调用 `rawFree`；更通用的做法是使用 allocator wrapper，让 wrapper 的 vtable `free` 在转交 backing allocator 的 `rawFree` 前清零。
- `process.run` 的错误路径会在内部释放尚未返回的输出和环境 block；需要保证这些内存也清零时，可为这次调用提供局部 allocator wrapper，并让 `resize`、`remap` 返回失败以迫使增长走 allocate-copy-secure-free。wrapper 只能在它分配的全部内存于当前调用内释放时使用，不能让返回 allocation 超过 wrapper context 的生命周期。
- 敏感 `Writer.Allocating` 不能依赖自动增长，因为 `ensureTotalCapacityPrecise` 可能复制后直接 `rawFree` 旧 allocation；应一次性保守预分配，最终复制出拥有型结果，再清零整个中间 capacity 后调用其同样使用 `rawFree` 的 `deinit`。每次 secret 替换产生的新旧 owned slice 也应在交接所有权时清零旧 slice。
- `testing.checkAllAllocationFailures` 会先统计成功路径的 allocation 数量，再逐个注入 OOM，并检查错误是否被吞掉、allocation 数量是否不确定以及字节是否全部释放。它适合验证确定性分配流程的所有权，但不会证明释放前内容已经清零；安全清零仍需使用可观察 backing storage 的独立测试。

关键源码：

- `../zig/lib/std/process.zig`：`RunError`、`RunOptions`、`RunResult`、`run`
- `../zig/lib/std/process/Child.zig`：`Term`、`Term.success`、`kill`、`wait`
- `../zig/lib/std/Io.zig`：`Timeout.toDeadline`、`Future.cancel`、`concurrent`
- `../zig/lib/std/Io/File/MultiReader.zig`：`fill`、`deinit`、`toOwnedSlice`
- `../zig/lib/std/process/Environ.zig`：`Map.validateKeyForPut`、`putMove`、`clone`、`deinit`
- `../zig/lib/std/Uri.zig`：`parse`、`writeToStream`、`Format.Flags.authentication`
- `../zig/lib/std/crypto.zig`：`secureZero`
- `../zig/lib/std/mem/Allocator.zig`：`VTable`、`free`、`rawAlloc`、`rawRemap`、`rawFree`
- `../zig/lib/std/testing/FailingAllocator.zig`：allocator wrapper 的 vtable 实现模式
- `../zig/lib/std/testing.zig`：`checkAllAllocationFailures`
- `../zig/lib/std/Io/Writer.zig`：`Allocating.ensureTotalCapacityPrecise`、`deinit`、`toOwnedSlice`
- `../zig/lib/std/Random.zig`、`fs.zig`、`json.zig`：实现模块聚合独立测试文件

验证基于 Zig `0.17.0-dev.2248+3f6a02acd`、源码 revision `3f6a02acdda41190eab7d57a9f037df9d4853631`。项目测试用真实子进程覆盖双流捕获、cwd、环境覆盖、stdin EOF、非零与 signal 结束、独立输出上限、总 timeout 和 future cancellation；脱敏测试覆盖重叠或重复 secret、空 secret、credential URL、多个 `@`、引号边界、malformed URL 和逐 allocation 失败清理，并分别观察 allocator wrapper 与直接 `rawFree` 路径的释放前清零。若 `process.run` 不再使用循环 fill、环境 map 或 `Allocator.free` 改变释放语义、URI formatter 改变 authentication 行为，或 allocating writer 获得可注入的安全释放策略，必须重新核对本节。

## HTTP 响应与 typed JSON 所有权

适用范围：读取完整 HTTP response body 后，通过 `std.json` 绑定含字符串或切片字段的 Zig struct。

- `std.json.parseFromSlice` 默认使用 `.alloc_if_needed`，解析结果可能直接引用输入 slice。若 response body 会在 helper 返回前释放，必须设置 `.allocate = .alloc_always`，并让调用方最终调用 `std.json.Parsed(T).deinit()`。
- GitHub API 响应使用 `.ignore_unknown_fields = true` 保持向前兼容；不要改变默认的重复字段报错，也不要为必需字段提供默认值。API 可返回 `null` 的字段必须显式使用 optional 类型。
- `std.http.Client.Request.RedirectBehavior.unhandled` 表示把 3xx response 交给调用方，且不会自动向新地址重发请求。携带 Authorization 且不需要跳转的 API client 应使用该模式，以便保留状态分类并避免凭据跨地址转发；`.not_allowed` 会在收到跳转时返回 `error.TooManyHttpRedirects`。

关键源码：

- `../zig/lib/std/json/static.zig`：`ParseOptions.allocate`、`parseFromSlice`、`Parsed(T).deinit`
- `../zig/lib/std/json/static_test.zig`：typed struct、optional、未知字段和重复字段测试
- `../zig/lib/std/http/Client.zig`：`Request.RedirectBehavior`、`Request.receiveHead`、`Request.redirect`、`Request.deinit`
- `../zig/lib/std/http/test.zig`：request/response body 和 header 读取测试

验证基线为 Zig `0.17.0-dev.2248+3f6a02acd`、源码 revision `3f6a02acdda41190eab7d57a9f037df9d4853631`。本仓库通过释放原 response buffer 后继续读取 typed 字符串、离线 transport 状态分类及 `zig build test` 验证这些结论；工具链 API 或 response 生命周期变化时必须重新核对。

### GitHub 客户端源码审查索引

以下是 Issue #15 实现与 rebase 复审实际读取的当前 Zig 工具链源码及形成的判断，供后续 HTTP 客户端工作直接定位；它们仍以对应 revision 为适用边界：

- `../zig/doc/langref.html.in` 的 `Comments`、`Style Guide` 和 `Doc Comment Guidance`：`//!` 描述文件 namespace，`///` 描述紧随其后的声明；类型和返回类型的 callable 使用 `TitleCase`，普通函数使用 `camelCase`，其他值使用 `snake_case`；命名应避免 FQN 重复，文档应补充所有权和不变量而不是复述名字。本项目因此从内部 `github/client.zig` 直接向 `github` facade re-export 类型，公开路径使用 `github.Client` 而不是 `github.client.Client`。
- `../zig/lib/std/http.zig` 的 `Method.requestHasBody`、`Method.responseHasBody`、`Method.idempotent`、`Status` 和 `Status.class`：GET 是幂等操作，POST 默认不是；对 GraphQL POST 自动重试必须由更窄的领域契约保证操作可重复执行，不能仅因它承载 query 文本就推断幂等。
- `../zig/lib/std/http/Client.zig` 的 `RequestOptions`、`request`、`Request.sendBodiless`、`Request.sendBody`、`Request.receiveHead`、`Request.RedirectBehavior`、`Request.deinit` 和 `Response.Head.iterateHeaders`：request 必须 `deinit`；`.unhandled` 把 3xx 返回调用方；`extra_headers` 会跨域保留，而 `privileged_headers` 会在跨域 redirect 时移除，所以 Authorization 应放入后者，即使当前客户端禁止自动 redirect。标准库用不同动词区分创建请求、发送 body 和接收响应；本项目相应使用 `sendWithRetry` 与 `sendOnce` 区分策略编排和单次 transport 调用。
- `../zig/lib/std/http/test.zig` 的客户端请求、response body、header iterator、trailer 和 redirect 用例：官方模式是在 request 创建后立即 `defer req.deinit()`，读取 head 后通过 response reader 消费或分配 body，并由拥有该 allocation 的 allocator 释放。
- `../zig/lib/std/json.zig` 与 `../zig/lib/std/http.zig` 的 facade 和测试聚合：公共 namespace 可以通过 alias 暴露同名子目录中的类型与函数，并在根测试块显式导入实现测试；对外模块应使用文件级 `//!` 说明整体职责。项目内多文件模块采用 `name.zig + name/`，因此入口是 `github.zig`，而不是额外的 `github/root.zig`。
- `../zig/lib/std/json/static.zig` 的 `ParseOptions`、`Parsed`、`parseFromSlice` 和 `parseFromTokenSource`：`Parsed(T)` 拥有 arena，调用方必须 `deinit`；构造时以两层 `errdefer` 分别保护 arena 对象与内部 block；slice 输入默认可能借用 buffer。
- `../zig/lib/std/json/static_test.zig` 的 typed struct、unknown field 和 duplicate field 用例，以及 `../zig/lib/std/json/Scanner.zig` 的 `AllocWhen` 文档：未知字段可显式忽略，重复字段默认报错；需要让字符串越过输入 buffer 生命周期时使用 `.alloc_always`。
- `../zig/lib/std/json/Stringify.zig` 的 `valueAlloc` 和对应测试：返回的 JSON slice 由传入 allocator 拥有，错误集为 `OutOfMemory`，调用方在请求结束后负责释放。
- `../zig/lib/std/Io/Writer.zig` 的 `fixed`、buffered write 和 fixed-buffer 测试：固定 writer 容量耗尽时保留已经写入的前缀并返回 `WriteFailed`；错误诊断必须先逐段脱敏再写入固定 buffer，不能先截断原文后脱敏。
- `../zig/lib/std/testing.zig` 的 `checkAllAllocationFailures`：它先测量成功路径的 allocation 数，再逐个注入 OOM，并检查泄漏、吞掉的 OOM 和不确定的 allocation 次数；适合验证拥有多个 allocation 和 `errdefer` 的公开构造/解析链。
- `../zig/lib/std/Uri.zig` 的 `parse`、`parseAfterScheme`、`Component` 和 userinfo 测试：解析结果借用原始 URL；host、user 和 password 是分离的 component。只接受 GitHub API 绝对 URL 时应比较 scheme/host 并拒绝任何 user/password，不能靠字符串前缀判断来源。
- `../zig/lib/std/mem.zig` 的 `startsWith`、`findScalarPos`、`findAnyPos` 和 `findLast`：这些 API 返回原 slice 中的索引且找不到时返回 `null`。完整 URL 脱敏需要用最后一个 `@` 划分 userinfo，并在完整输入上定位 query/authority 边界后再写入 bounded diagnostic。
- `../zig/lib/std/fmt.zig` 的 `parseUnsigned` 及测试：它只接受无符号表示，并区分 `InvalidCharacter` 与 `Overflow`。GitHub rate-limit header 不是主响应 payload，解析失败时保留为缺失 metadata，而不把整个 API 响应改判为失败。
- `../zig/lib/std/math.zig` 的 `mul` 与 `../zig/lib/std/Io.zig` 的 `Duration`、`sleep`：`mul` 以 `error.Overflow` 报告溢出；`Duration` 以 `i96` 纳秒存储。指数退避使用 checked multiplication 并饱和到 `Duration.max`，初始化时拒绝负 duration，离线测试通过注入 `std.Io.failing` 避免真实睡眠。

本仓库据此使用文件级模块文档、typed facade、Authorization privileged header、GraphQL 重试契约、完整响应所有权和 allocation-failure 穷举测试。验证覆盖离线 REST/GraphQL、错误分类、secret redaction、typed JSON 生命周期和完整项目测试图；Zig revision、HTTP redirect 实现、JSON arena 模型或 Writer fixed-buffer 行为变化时必须重新审查这些结论。

## 初始化参数与运行时依赖

适用范围：同时接收调用方策略、allocator、I/O 和可替换 adapter 的内部组件初始化 API。

- 当前标准库并没有要求所有初始化参数必须放进一个 options struct。`std.testing.FailingAllocator.init(internal_allocator, config)`、`std.zig.Directories.init(arena, io, options)`、`Compilation.create(gpa, arena, io, diag, options)` 和 TLS `Client.init(input, output, options)` 都把主要能力作为显式位置参数，把策略值集中在最后的 config/options 中。
- 本仓库据此采用 `Client.init(allocator, io, config)`。需要替换 HTTP transport 时使用 `initWithTransport(allocator, io, transport, config)`；重试等待直接使用已经注入的 `std.Io.sleep`，不再额外定义重复的 waiter 接口。这是项目的职责建模，不是 Zig 语言规则；当能力的所有权或调用方变化时应重新检查边界。
- User-Agent 表示发起请求的产品身份，不能由通用 GitHub client 猜测个人或部署身份。因此 `Config.user_agent` 是必填值，由装配层显式提供；客户端不保存个性化默认值。

关键源码：

- `../zig/lib/std/zig.zig`：`Directories.InitOptions`、`Directories.init`
- `../zig/src/main.zig`：`std.zig.Directories.init` 调用点
- `../zig/lib/std/testing/FailingAllocator.zig`：`Config`、`init`
- `../zig/src/Compilation.zig`：`CreateOptions`、`create`
- `../zig/lib/std/crypto/tls/Client.zig`：`Options`、`init`
- `../zig/lib/std/Io.zig`：`VTable.sleep`、`sleep`、`failing`
- `../zig/lib/compiler/resinator/compile.zig`：`CompileOptions`、`compile`
- `../zig/lib/compiler/resinator/main.zig`：`compile` 调用点

验证基线仍为 Zig `0.17.0-dev.2248+3f6a02acd`、源码 revision `3f6a02acdda41190eab7d57a9f037df9d4853631`。通过 GitHub client 的显式初始化调用、注入 transport 与 `std.Io.failing` 测试、allocation-failure 测试和完整项目构建验证；若上述初始化 API 或本项目装配边界变化，需要重新审查。

## 远端依赖与包身份

适用范围：`build.zig.zon` 中的远端依赖。

- `.url` 是获取位置，`.hash` 才是期望包内容的权威身份。两者同时存在时，fetch 会对解包并应用 manifest `paths` 后的内容重新计算 hash，不匹配即失败。
- `git+https://host/repository.git#<commit>` 使用 Git 协议读取显式 ref。当前实现能直接解析 commit OID，checkout 后以仓库根作为候选包根，适合锁定 Git revision。
- `https://...tar.gz` 是通用归档输入。它同样可以可靠锁定内容，但包根还取决于归档条目是否具有可识别的共同顶层目录；托管平台改变归档布局时可能改变根目录识别或内容 hash。
- fetch 在候选包根读取 `build.zig.zon`。读取成功时，缓存名使用 manifest 的 `name`、`version`、fingerprint 和内容摘要；找不到 manifest 时，源码明确使用占位名称 `N`、版本 `V`，形成 `N-V-...`，这就是“裸包”。

Issue #13 调查期间曾观察到 `N-V-.../<repository>-<commit>/build.zig.zon`：manifest 位于 fetch 选定根目录的下一层，因此外层被判为裸包。这个现场只证明当时那次归档获取没有选中共同顶层目录，不能推导为所有 GitHub tarball 都有问题；同一 revision 的标准 `archive/<commit>.tar.gz` 后续用当前 `zig fetch` 能得到正常的 `clap-0.12.0-...` hash。本项目仍选择 `git+https` 加完整 commit，以直接表达 Git revision 并减少对归档包装目录的依赖。

关键源码：

- `../zig/lib/compiler/Maker/Fetch.zig`：`initResource`、`unpackResource`、`unpackTarball`、`unpackGitPack`、`loadManifest`、`computedPackageHash`
- `../zig/lib/compiler/Maker/Package.zig`：`Hash.init`、`Hash.toSlice`
- `../zig/lib/std/tar.zig`：`Diagnostics.findRoot`、`extract`

验证依赖解析路径时使用 `zig build --verbose`。不要直接在 `zig-pkg/<hash>` 中运行依赖构建；那会把依赖自己的 `.zig-cache` 和 `zig-out` 写入可再生的包缓存。需要独立验证上游构建时，应在临时 checkout 中执行，或把 `--cache-dir` 与 `--prefix` 指向临时目录。

## 当前锁定依赖

| 依赖            | revision                                   | 导入模块 | 验证                                             |
| --------------- | ------------------------------------------ | -------- | ------------------------------------------------ |
| zig-clap 0.12.0 | `05faf3905e8548f5cc269a8836e154065e70128d` | `clap`   | CLI 解析、诊断和借用单测；上游默认构建和测试              |
| ymlz 0.7.1 fork | `e0fe6a73b5df0fa8a37128c582514cba44b985d2` | `root`   | typed mapping smoke、配置分层测试；上游默认构建和测试      |

ymlz 发布包的 manifest `paths` 不包含上游测试使用的 `resources/`，因此从包缓存运行其完整 fixture 测试会得到 `FileNotFound`。这不影响项目内实际调用公开解析 API 的 smoke test；升级依赖时仍需在完整 checkout 中重新运行上游测试。

## ymlz Typed Binding 的校验边界

适用范围：把不受信任的 YAML 配置绑定到当前项目的显式 struct；不适用于开发通用 YAML parser。

- 锁定的 ymlz `Ymlz(T).parse` 遇到未知字段会 `@panic`，按字段数推进解析而不检测重复键，并以 `undefined` 初始化目标后只将 optional 字段置空。缺失的非 optional 字段因此不能作为调用方可观察的配置错误。
- ymlz 的 optional numeric 字段存在时会把 `?T` 传给只识别裸 `.int`/`.float` 的 numeric parser，返回 `error.UnrecognizedSimpleType`。配置边界应先按 schema 校验 scalar，再把这类 raw 值绑定为 optional text，并在归一化阶段转换为目标数字类型。
- 在 typed binding 前使用仅理解项目 mapping 层级、允许键和 list 形状的 validated reader。它负责拒绝未知键、重复键、旧入口、危险缩进和非法 scalar；不能借此扩张成第二套通用 YAML 实现。
- ymlz parser 和 raw result 可以放在临时 `ArenaAllocator` 中。这样 `loadReader` 任意错误都由 arena 统一清理，不需要在没有完整 result 时调用 `Ymlz.deinit`；校验后的公开结果再复制到独立 arena。
- 对外 parsed result 采用 `std.json.Parsed` 的所有权模式：结构体持有 `*ArenaAllocator` 和 typed value，`deinit` 先保存 child allocator，再释放 arena 并销毁 arena 对象。成功结果不得借用输入；失败诊断若借用 offending text，API 文档必须声明其生命周期。

## 解析器适配器与返回值所有权

这些结论来自当前 Zig revision 的标准库和锁定的 ymlz 源码，可复用于其他 typed text/config parser：

- ymlz 的 `Ymlz(Destination)` 是按目标 struct 生成的 parser 类型；`init(allocator)` 创建 parser 实例，`loadRaw` 只是构造内置 `RawReader` 后转调 `loadReader`，而 `loadReader` 要求传入对象提供 `readLine(allocator) !?[]const u8`。因此文件、内存和预检后的文本可以共享同一 typed binding，而不必让 ymlz 负责输入来源。
- ymlz 的 parser 实例同时记录自己分配的字符串/列表；官方测试在成功解析后调用 `ymlz.deinit(result)`。若调用方把 parser 和 raw result 都放进临时 arena，则错误路径可由 arena 统一回收；只有把结果复制到独立拥有的 arena 后，才能让临时 parser 生命周期结束。
- `std.json.parseFromTokenSource` 是当前 Zig 对 arena-owned 返回值的直接模板：先由父 allocator 分配 `ArenaAllocator` 对象，再用 `errdefer` 覆盖对象分配和 arena 初始化失败，最后把解析结果放进 arena；成功时返回 `Parsed(T)`，由调用方显式 `deinit`。
- `ArenaAllocator.init(child_allocator)` 中的 child allocator 是 arena 释放内部 block 时使用的父 allocator。`arena.deinit()` 只释放 arena 管理的 block；如果 `ArenaAllocator` 结构体本身也由父 allocator 分配，必须另行用保存下来的 child allocator `destroy` 它。
- Zig 语言参考定义 `defer` 为离开作用域时无条件执行，`errdefer` 仅在从该作用域错误退出时执行。临时输入/parser 使用 `defer`；只有成功返回后转移给调用方的资源，才使用 `errdefer` 保护构造失败路径。

关键源码：

- `zig-pkg/ymlz-0.7.1-TG82aTbZAABsQ7DIERSAObNJNviwTHhtzM_KO-L3Xgo_/src/root.zig`：`Ymlz`、`loadReader`、`parse`、`parseField`、`parseBooleanExpression`、`parseNumericExpression`、`deinit`
- `../../zig/lib/std/heap/ArenaAllocator.zig`：`init`、`allocator`、`deinit`
- `../../zig/lib/std/json/static.zig`：`Parsed`、`parseFromTokenSource`
- `../../zig/doc/langref.html.in`：`defer` 与 `errdefer` 语义

验证方式：配置单元、公开 API 集成和生产配置 E2E artifacts 全部通过；`std.testing.checkAllAllocationFailures` 穷举验证 parse 成功路径的分配失败清理。若升级 ymlz 或 Zig revision，必须重新检查上述解析和 arena 所有权实现，尤其是 optional struct/numeric 与错误清理行为。

## CLI 切片与环境凭据的借用

适用范围：使用锁定的 zig-clap 从调用方提供的 argv 切片解析字符串参数，并从 `std.process.Init.environ_map` 读取运行期凭据。

- `clap.args.SliceIterator` 不分配或复制参数，只逐项返回调用方 argv 中的切片。`clap.parsers.string` 也直接返回收到的切片。
- `clap.parseEx` 的结果仍由调用方负责调用 `deinit`；该清理只释放解析器为重复参数和位置参数集合分配的容器。对于 `.one` 字符串参数，清理解析结果后，值仍借用原 argv，调用方必须保证 argv 覆盖应用输入的使用期。
- zig-clap 使用参数的最长名称原样生成结果字段，不会把连字符归一化为下划线。`--config` 可通过 `result.args.config` 访问；`--dry-run` 则必须使用 `@field(result.args, "dry-run")` 或 `result.args.@"dry-run"`。改变长参数名称也会改变生成的字段 API。
- `std.process.Environ.Map.get` 返回 map 自有值的借用。该值在对应键被删除、map 调整或 map 销毁后失效。启动代码创建 `Init.environ_map`，并在 `main` 返回后统一销毁，因此应用入口可以在本次调用期间借用 token，但不得将它保留到 `Init` 生命周期之外。
- zig-clap 只在 `Clap.err` 错误路径写入 `Diagnostic`。包装 API 若接收调用方可复用的 diagnostic 输出参数，应在入口先重置为默认值，避免后续成功调用或其他错误路径保留上一次解析失败的上下文。
- `clap.Diagnostic.report` 只格式化解析器记录的参数名称或原始位置参数，不提供通用脱敏。凭据优先级和空值语义应在环境映射边界完成，不为只读应用输入复制 secret，也不得把 secret 放入 argv 或传给参数帮助、诊断接口。

关键源码：

- `../../zig/lib/std/process/Environ.zig`：`Map.put`、`Map.get`、`Map.swapRemove`、`Map.deinit`
- `../../zig/lib/std/start.zig`：`callMain` 对 `environ_map` 的创建、传入和清理
- zig-clap `clap/args.zig`：`SliceIterator`
- zig-clap `clap/parsers.zig`：`string`
- zig-clap `clap/streaming.zig`：`Clap.err`、`Clap.normal`
- zig-clap `clap.zig`：`parseEx`、`ResultEx.deinit`、`Arguments`、`Diagnostic.report`、`help`

验证基线：Zig `0.17.0-dev.2248+3f6a02acd`、源码 revision `3f6a02acdda41190eab7d57a9f037df9d4853631`、zig-clap revision `05faf3905e8548f5cc269a8836e154065e70128d`。本仓库 CLI 单测在解析函数返回后检查 argv 与环境值的指针身份，并覆盖帮助、诊断、凭据优先级和空值回退。工具链或 zig-clap revision 改变时必须重新核对这些所有权结论。
