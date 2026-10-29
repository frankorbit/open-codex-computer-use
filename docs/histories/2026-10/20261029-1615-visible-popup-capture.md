## [2026-10-29 16:15] | Task: 修复部分出屏弹层的观察覆盖范围

### Execution Context
- Agent: Codex desktop
- Runtime: macOS native Swift package

### User Query
继续实机复测，遇问题分析修复；不放宽停止规则，不重复已发送输入。

### Changes Overview
- 模型弹层截图选择完整位于单屏的最大可见交集，采集结果保留实际 captureBounds。
- 观察文本明确局部覆盖，不把未截图的窗口区域视为已核实。
- 整窗透明蒙版不缩放到局部截图；实时预览保持原整窗路径。
- 不改点击投递、权限、超时、取消、发送前接收者校验或一次性凭证机制。

### Design Intent
菜单顶部出屏时，原截图入口要求整个菜单完整位于单屏，因此持续 imageUnavailable。已有坐标租约支持 captureBounds，但生产采集未提供局部覆盖。用显示器交集提供可验证几何，避免硬编码偏移和跨屏拼接。

### Validation
- 完整 Swift 包：719 XCTest，8 项跳过，0 失败；77 Swift Testing 通过。
- 最终几何定向：9 项通过，覆盖真实负 y 菜单、多显示器负坐标、缩放、越界、未知范围、一次性 token 和回读失败不重放。
- SwiftFormat 已检查改动；保留不相关旧格式。SwiftLint 剩余 7 项均与 HEAD 基线一致，未增加违规（基线原有 8 项）。
- 本记录时尚未以新签名 App 做实机验收；不把纯测试标为端到端通过。

### Files Modified
- packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupWindowCapture.swift
- packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupSystemCapture.swift
- packages/OpenComputerUseKit/Sources/OpenComputerUseKit/PopupWindowImage.swift
- packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewPopupRegion.swift
- packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupObservation.swift
- packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/PopupCaptureGeometryTests.swift
- docs/ARCHITECTURE.md
