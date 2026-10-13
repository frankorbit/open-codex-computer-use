## 2026-10-13 | Task: 弹层点击事件对照与单通道投递

### 用户诉求

排除用户手动退出 Helper，针对 WPS 颜色弹层做事件对照，找到有效且不破坏既有后台行为的方案。

### 变更

- 新增内部 SkyClickProfile；凭证绑定的弹层使用 moved/target down/up 与 SkyLight 单通道。
- 普通窗口仍默认原有 primer 与左键双通道；右键与双击、焦点准备均保持不变。
- 保留 TTL、身份/几何/接收者复验、单次 token、异常无重放和无前台 fallback。
- 新增单通道、默认通道、down 前失效、配对 up 及失败无 fallback 回归。

### 原因与验证

实测双通道移除 primer 仍不选色；独立 public PID 与 SkyLight 均能实际改变标题颜色。最终选 SkyLight 保持原路由语义。工具栏和字体对话框色板都取得实际颜色变化证据；不是 WPS 名称或坐标特判。

测试、复审和未验收边界见 [完成计划](../../exec-plans/completed/2026-10-13-popup-event-delivery.md)。本轮没有提交、推送、改 pin 或替换 Today。

### 关键文件

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyClickSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupClick.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SkyClickSubmissionTests.swift`
