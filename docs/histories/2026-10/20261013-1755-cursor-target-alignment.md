## 2026-10-13 17:55 | Task: 修复屏幕边缘虚拟光标与输入目标错位

### Execution Context
- Agent: Codex
- Runtime: 本地 macOS 工作区

### 用户诉求
WPS 全流程已通过，但画中画内偶发蓝色光标与实际点击位置不一致；修复显示偏移。

### 改动与原因
- `SoftwareCursorOverlay` 原先按 visibleFrame 和整幅光标尺寸限制尖端位置，顶部、边缘目标会被向内推；输入事件仍使用原目标，画中画却复用了受限的显示位置。
- 删除移动、点击脉冲、settle 和动画推进中的该限制，允许边缘光晕被裁剪，保持尖端目标不变。屏幕外后台目标也不再被挪到当前屏幕边缘。
- 不修改原生输入坐标、AX/SkyLight 选择、权限、窗口身份检查、弹层捕获或 Today 菜单工作流。动画在途帧仍有移动过程，不能把本修复理解成截图与输入严格同步。
- 动画推进方法改为包内可见，供 `@testable` 回归测试调用；没有新增公开 API。

### 验证与复审
- 新测试直接调用生产动画路径，覆盖实际屏幕四边、中心、负坐标屏幕外窗口、idle、窗口原点转换和画中画映射；不创建窗口或投递输入。旧实现出现 36 项失败，修复后通过。
- 完整 `swift test`：512 项 XCTest 中 7 项显式跳过，0 失败；51 项 Swift Testing 通过。
- 修改范围的 SwiftFormat 检查通过；SwiftLint 新测试无告警，原文件保留 8 项既有命名/行长/文件长度/类型长度问题，未新增类别或数量，文件及类型长度有所减少。
- 文档骨架与 diff whitespace 检查通过；`make check-repo` 的 hygiene 阶段因 HEAD 中已缺失的 11 个模板/配置文件失败，与本次修改无关。仓库没有 `just check` 入口。
- 复审确认实际点击和显示的位置不再因屏幕边界限制而分离；窗口位置换算和预览画布映射没有改动。
- 本轮没有重新运行 WPS GUI 验收，也没有替换正在运行的 App。本轮按用户要求提交并推送原生依赖修复；Today pin 随后续集成更新。

### 文件
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorOverlay.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SoftwareCursorPositionTests.swift`
- `docs/ARCHITECTURE.md`
