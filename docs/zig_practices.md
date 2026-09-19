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

这是当前标准库用于聚合子模块测试的常见形式，可在 `std/json.zig`、`std/fs.zig`、`std/Random.zig` 和 `std/Io/Threaded.zig` 等文件中找到。新增模块的测试应由最近的模块根纳入，而不是依靠未被引用的文件自动发现。

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
| zig-clap 0.12.0 | `05faf3905e8548f5cc269a8836e154065e70128d` | `clap`   | 参数声明 smoke test；上游默认构建和测试          |
| ymlz 0.7.1 fork | `e0fe6a73b5df0fa8a37128c582514cba44b985d2` | `root`   | typed mapping `loadRaw` smoke test；上游默认构建 |

ymlz 发布包的 manifest `paths` 不包含上游测试使用的 `resources/`，因此从包缓存运行其完整 fixture 测试会得到 `FileNotFound`。这不影响项目内实际调用公开解析 API 的 smoke test；升级依赖时仍需在完整 checkout 中重新运行上游测试。
