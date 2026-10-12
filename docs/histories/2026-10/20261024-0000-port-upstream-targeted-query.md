## [2026-10-24 00:00] | Task: 移植上游定向 AX 查询

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 在新分支上挑入上游 query（8fdda42）和 selective observation 的 macOS 部分，保留 fork 现有行为，跑 fork 和 Today 测试。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`, `scripts/node-repl`, `docs`

**Key Actions:**
- **挑入上游 `query`**：保留上游的有界 AX 查询、单调且不复用的高位索引，以及动作前重新校验的语义。
- **截图开关沿用 fork 命名**：`WindowCapture.resolve` 继续使用 `includeImage`，并采纳上游“不截图时不读取截图配置”的改动。
- **点击保留 fork 校验**：元素点击保留 fork 的参数校验和 `click_target` 诊断，只把取快照的入口改为 `snapshotForAction`。查询索引因此走查询登记表，普通索引仍走快照缓存。
- **`query` 按只读观察分发**：与 `get_app_state` 相同，不进入菜单焦点交互，也不点亮输入预览状态。
- **REPL `getApp`**：支持 `initialState:false`；默认路径保留 fork 的 `initialize:true` 和首帧图片输出。
- **测试与文档**：工具总数断言从 10 改为 11；README 与 ARCHITECTURE 只合入 query 相关内容，不带入未挑入的 `doctor --json` 说明。

### 🧠 Design Intent (Why)
脚本需要按角色和文字找控件，才能在一次调用里串联多个步骤。上游 `query` 不渲染完整树、不截图，也不激活窗口，比在 fork 内重新实现一个整树观察工具更轻、更安全。合并时以 fork 已验证的后台输入、初始化和诊断行为为准。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/TargetedQuery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/ApplicationOpeningTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`
- `README.md`, `docs/ARCHITECTURE.md`
