## [2026-10-24 00:10] | Task: 移植上游 macOS 按需观察

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 在新分支上挑入上游 query（8fdda42）和 selective observation 的 macOS 部分，保留 fork 现有行为，跑 fork 和 Today 测试。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`, `apps/OpenComputerUse`, `scripts/node-repl`, `docs`

**Key Actions:**
- **只移植 macOS**：从上游 31a7d7d 只取 macOS 的 `include_ax` / `include_screenshot`、JS `includeAX` / `includeScreenshot` 和 CLI snapshot 参数，不带入 Windows / Linux 实现、CI 和测试脚本。
- **接入 fork 的快照缓存**：没有采用上游的 `snapshotsByApp` 存储。`SnapshotDependencies.build` 增加采集选项参数，`get_app_state` 的初始化、普通观察和窗口放置后的最终观察都按请求选项采集；窗口放置前用于定位窗口的中间读取仍是完整采集。
- **编号失效**：不含 AX 的观察会替换缓存快照，旧元素编号随之失效，同时清除该进程的查询编号。
- **坐标输入拦截**：快照没有截图时，坐标点击和拖拽在发送输入前拒绝。
- **保持 fork 行为**：CLI snapshot 继续使用 `initialize:true` 与 `primaryText` 输出；REPL 的后续观察继续显式携带 `initialize:false`，测试期望同步更新。
- **测试改写**：上游 SelectiveObservationTests 改为通过 `get_app_state` 和注入依赖走 fork 缓存验证；坐标拦截测试注入一个“被调用即失败”的点击后端，确认拒绝发生在输入之前。fork 的 fixture 不返回选中文字，相关断言已移除。

### 🧠 Design Intent (Why)
`waitFor` 轮询和动作后的读状态大多不需要截图。跳过截取和编码可以降低每次观察的开销，同时不改变默认的完整采集，也不放宽 fork 已有的初始化、编号和输入安全约束。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppSnapshotCache.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SnapshotObservationOptions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SelectiveObservationTests.swift` 及构建闭包注入点
- `apps/OpenComputerUse/Sources/OpenComputerUse/MacOSAppAgentProxy.swift`, `OpenComputerUseMain.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`, `open-computer-use-repl.test.mjs`
- `docs/selective-observation.md`, `docs/ARCHITECTURE.md`, `docs/references/js-repl.md` 等文档
