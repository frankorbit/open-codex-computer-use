## [2026-10-24 15:30] | Task: 辅助功能输入前调长消息超时

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 执行辅助功能动作和写值前把元素的消息超时调长。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **`prepareAXInput`**：输入前把目标元素的 AX 消息超时设为 2 s（`axInputMessagingTimeout`）。
- **接入点**：点击序列（`executeAXAction` 新增 `prepare`，只在确认要执行后、首次调用前执行一次）、坐标转 AX 按下、次要动作、AX 分页滚动、`set_value`、选中列表项、聚焦/选中属性写入、`InputSimulation` 的动作与属性写入，以及 sky_key 菜单项按下。
- **测试**：`AXActionExecutionTests` 覆盖准备步骤的顺序、未执行时不调整，以及超时取值。

### 🧠 Design Intent (Why)
观察时为保证读取速度，元素的消息超时被设为 0.05–0.1 s，输入复用同一批元素。打开或关闭模态对话框、保存等动作的回复往往更慢，短超时让已经生效的动作返回 `cannotComplete`，被报成“效果未知”，模型只能多观察一轮甚至放弃。调长后返回值如实反映动作；真正超时仍按效果未知处理，不重试、不改用其他输入路径。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AXActionExecution.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyKeyboardSimulation.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AXActionExecutionTests.swift`
