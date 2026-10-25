## [2026-10-24 22:15] | Task: 弹层截图改为硬件优先

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 在 fork 里把弹窗截图（概览和实时预览两处）改用 SLSHWCaptureWindowList，拿不到时再退回按显示器过滤、只包含该窗口并裁剪的方式，并校验图片尺寸，补测试。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`docs`

**Key Actions:**
- **`PopupWindowImage`（新增）**：概览与实时预览共用的弹层截图。`hardware` 读该窗口的硬件缓冲区，沿用主窗口截图的几何规则（完整落在一块显示器内、与完整窗口等比）；`displayCrop` 用指定窗口白名单加显示器本地裁剪，关闭隐式子窗，按配置尺寸校验。
- **概览**：`HoverPopupSystemCapture` 先用硬件图，并以窗口 bounds 作为图片区域（可用于弹层点击）；退回 `HoverPopupWindowCapture` 的显示器裁剪。删除独立窗口过滤器路径。
- **实时预览**：`LivePreviewPopupCapture` 同样硬件优先、退回显示器裁剪；删除独立窗口回退及仅供它使用的 `matchesIndependentContent` / `matchesCapturedFrame`。
- **帧状态**：单张截图样本不带帧状态，`frameIsComplete` 只在有状态时要求 complete。
- **`WindowCaptureGeometry.activeDisplayBounds`**：从主窗口截图中提取，供两处共用。
- **测试**：硬件图尺寸与显示器包含校验、跨屏/离屏不读硬件、帧状态判定；删除已无对应实现的独立窗口校验测试。

### 🧠 Design Intent (Why)
Numbers 保存失败与提醒事项“详情面板打不开”的共同原因：弹层截图用 `desktopIndependentWindow`，系统把 sheet / popover 与父窗口分组，交付给模型的是整窗缩略图，模型读不到面板内容。实机对同一保存面板对比：独立窗口过滤器得到整组缩略图；硬件缓冲区与显示器裁剪都只含面板本身。另外发现实时预览的显示器裁剪路径因帧状态校验一直返回空，弹层从未叠加到预览上。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/PopupWindowImage.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupSystemCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupWindowCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewPopupCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewPopupRegion.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/WindowCaptureGeometry.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LivePreviewPopupRenderingTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/exec-plans/active/2026-10-12-wps-popup-observation.md`
