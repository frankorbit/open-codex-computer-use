## [2026-10-24 14:40] | Task: 忽略系统窗口共享指示器

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 确认紫色指示器的窗口归属和是否由实时预览的窗口截取触发；确认后让弹出窗口识别、遮挡校验和目标窗口选择都忽略它。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **实测确认**：在 macOS 26 上对单个窗口开启 ScreenCaptureKit 持续采集后，被采集应用自己的进程里会多出一个窗口（66×20 pt、层级 0、位于被采集窗口左上角内侧 16 pt，名为 `Window`），停止采集后消失；一次性截图不会产生它。它就是 Computer Use 截图里的紫色“窗口共享”按钮。
- **`WindowSharingIndicator`**：登记本进程正在持续采集的窗口；仅当本进程在采集同一应用的窗口时，才把该应用位于被采集窗口左上角、不超过 120×32 pt 的层级 0 小窗认定为指示器。不依赖可能随语言变化的窗口名。
- **实时预览**：开流前登记、停流后注销被采集窗口。
- **弹出窗口识别**：指示器不再作为 popup 返回。
- **坐标遮挡校验**：指示器不再被当成挡住目标点的同应用窗口；真实的 sheet、popover 仍然阻止点击。
- **目标窗口选择**：指示器可能成为应用的聚焦窗口，现在不会被选为观察和输入的目标窗口。
- **测试**：新增 `WindowSharingIndicatorTests`，覆盖实测几何、仅在采集期间识别、popup 过滤与遮挡校验。

### 🧠 Design Intent (Why)
实时预览持续采集目标窗口，系统因此在目标应用里插入共享指示器。它与应用同进程、排在主窗口之上，导致按 query 编号点击时坐标兜底被判为遮挡、指示器被当成 popup 交给模型，甚至被选为目标窗口，模型据此误以为有需要用户处理的系统弹窗。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/WindowSharingIndicator.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LiveWindowPreview.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupObservation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateWindow.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/WindowSharingIndicatorTests.swift`
