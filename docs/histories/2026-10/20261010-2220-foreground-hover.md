## [2026-10-10 22:20] | Task: 为宿主增加真实前台悬停

### Execution Context

- Agent: 当前 Codex 桌面会话
- Runtime: 本机 Swift Package；不经 Cua Driver

### User Query

> 修复虚拟鼠标无法触发原生颜色控件悬停的问题。

### Changes

- 默认上游 9 工具不变；宿主显式设置 `OPEN_COMPUTER_USE_FOREGROUND_HOVER=1` 才注册原生 `hover`。
- 参数为 `app`，以及互斥的 `element_index` 或截图坐标 `x`/`y`；`duration_ms` 默认 500，范围 0–2000 整数。
- 使用 ComputerUseService 当前已交付快照；移动前检查元素几何、窗口身份、前台目标、鼠标接收窗口和按键释放状态。
- 发送真实 HID mouseMoved，短暂悬停后强制只读回读，不受普通动作 read-back 开关影响。
- 不自动点击，不在失败后换路重放；输入后的失败报告可能已发生移动，并使快照失效。
- 原生诊断区分 hover/click。现有后台 AX、点击和拖拽策略不改变。

### Design Intent

视觉光标的绘制不触发 App tracking area。原先宿主侧 hover 根据独立枚举的窗口猜测截图归属，容易与上游快照不一致；真实移动改由持有快照的原生服务执行。不同窗口的 popup receiver 仍明确拒绝，不把同一 PID 当作输入授权。

### Validation

- fork 完整 Swift 测试：272 项 XCTest，7 项环境相关跳过，0 失败；另 6 项 Swift Testing 通过。
- 元素数值索引改用 `Int(exactly:)`，避免浮点上界舍入造成不可捕获的转换溢出。
- 新增 hover 参数、能力开关、校验顺序、失败不重放、缺失快照和诊断回归。
- 尚未宣称 TextEdit 实机选色通过；需宿主接入该版本、重建 App 后经真实链路验收。

### Files

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ForegroundHover.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputDiagnostics.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/ForegroundHoverTests.swift`
