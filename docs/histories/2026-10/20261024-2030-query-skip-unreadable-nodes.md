## [2026-10-24 20:30] | Task: 查询跳过不可读节点

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 先在 fork 里修查询：单个节点读失败时跳过该节点继续遍历，并在结果里标明部分节点不可读，补测试。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`docs`、`skills`

**Key Actions:**
- **`boundedTargetedWalk`**：非根节点读属性或读子节点失败时，只跳过它自己的子树，继续遍历；新增 `unreadableNodes` 计数。根节点（窗口本身）读不到时仍以 `ax_error` 停止。
- **停止原因**：先看遍历是否提前停止（`timeout` / `max_nodes` / `limit` / `ax_error`），没有提前停止但跳过过节点时，报 `unreadable_nodes`，`truncated` 为 true。
- **查询输出**：新增 `unreadable_nodes` 字段；工具说明、`targeted-query` 中英文文档和 skill 用法同步更新。
- **测试**：`TargetedQuerySafetyTests` 覆盖跳过不可读节点及其子树、子节点列表读取失败、根节点失败、提前停止原因优先、无跳过时不截断。

### 🧠 Design Intent (Why)
提醒事项实测中，5 次查询都只遍历了 61–94 个节点，就因 `ax_error` 整体中止（单节点读取超时 0.05 s），行尾的 ⓘ 按钮始终查不到，模型只好改用次要动作反复尝试，结果误加了旗标。一个慢的或已消失的元素，不应让整个窗口的查询失效。跳过的节点仍然标为结果不完整，空结果不会被当成“控件不存在”；总耗时仍受 2 秒截止时间约束。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/TargetedQuery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/TargetedQuerySafetyTests.swift`
- `docs/targeted-query.md`
- `docs/targeted-query.zh-CN.md`
- `skills/open-computer-use/references/usage.md`
