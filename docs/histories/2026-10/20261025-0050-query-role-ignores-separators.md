## [2026-10-25 00:50] | Task: query 角色匹配忽略分隔符

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 在 fork 里让 query 的角色匹配忽略空格、下划线和连字符（text field、text_field、AXTextField 都匹配），补测试，用开着的 Numbers 改名框真机验证。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`docs`

**Key Actions:**
- **`targetedRoleEquals`**：规范化时除 `AX` 前缀和大小写外，再去掉空白、下划线和连字符。
- **说明**：工具定义中 `role` 参数说明、`docs/targeted-query` 中英文文档同步。
- **测试**：`TargetedAXTests` 覆盖 `text field` / `text_field` / `text-field` / `AXTextField`、`pop up button` 等写法，以及分隔符不会让不同角色相等。

### 🧠 Design Intent (Why)
快照树把角色渲染成带空格的词（`text field`、`pop up button`），模型照抄后传给 query，原规范化只去 `AX` 前缀，`text field` 与 `AXTextField` 不相等。Numbers 复测中，模型按 `text field` 查改名框的 Name 输入框，连续两次 0 匹配（完整遍历 133 个节点）后放弃。修复后对同一改名框，三种写法都在同一窗口、同样 133 个节点内命中该输入框。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/TargetedAXTests.swift`
- `docs/targeted-query.md`
- `docs/targeted-query.zh-CN.md`
