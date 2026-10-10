## [2026-10-10 16:55] | Task: 解耦窗口验证与 AX 命中

### Execution Context

- Agent: Codex
- Runtime: Codex desktop

### 用户诉求

修复 fork 坐标 auto 对没有 AX 控件的有效窗口拒绝输入的问题，再同步宿主工程。

### 变更

- 查询前和输入前分别验证 WindowServer 窗口 ID、PID、几何、进程状态和实际同 Space 遮挡。
- 没有 AX 元素或未实现命中查询时允许鼠标路径，通信失败仍拒绝；未知 AXWindow 不执行 AX 动作。
- 左键单击/双击复用 sky_click 窗口定向输入，其他按钮沿 app_post；global 仅在显式开启后使用。
- 仅实际选择 global 或 app_post 鼠标路径后追加跨 App 遮挡检查，不误拦截后台 AXPress。
- 坐标 auto 回读使用 readOnly，避免后台输入之后的回读激活或重新打开目标窗口。
- AX 或鼠标发出后失败均不重试其他输入路径。

### 验证

- 213 项 Swift 非 live 测试通过；Node 30 项通过。
- 新增窗口消失、移动、归属变化、同 App 弹窗、不同/共享 Space、无 AX、通信错误及输入前二次验证回归。
- 复审发现不同 Space 误拦截和 global 开关过早影响 AX 两项问题，均已修正并补测试；另补 auto app_post 的前台和聚焦窗口校验，最终独立复审无剩余 P1/P2。
- GUI 未运行；第三方应用效果仍需宿主集成后人工验收。
- 文档检查通过；仓库卫生检查的上游既有缺项未改变。

### 关键文件

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateWindow.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateClick.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CoordinateWindowTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CoordinateClickTests.swift`

仅 sky_click 允许后台或跨 Space 的鼠标输入。auto 的 app_post 路径还要求目标是前台 App 的聚焦窗口且点击点无遮挡，否则输入前拒绝，避免 PID-only 事件误投同进程其他窗口。显式 app_post API 不变。
