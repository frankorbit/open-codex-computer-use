## 2026-10-10 | Task: 补齐 hover 独立弹层观察与定向点击

### Execution Context

- Agent: Codex desktop，主代理集成，独立子代理实现与复审。

### User Query

> 修复复审发现的 hover 回读遗漏独立 popup。

### Changes Overview

- `HoverPopupObservation` 保留主窗口帧，补充同 App、根窗口前、几何相关的可见弹层候选图片；排除已知普通 AXStandardWindow。截图前后和整批返回前复核身份、几何及根窗口焦点，最多尝试四张图片。
- 每张图旁明确 windowID、屏幕点范围、最终编码图片像素尺寸和一次性 token，图片 `_meta.ocuPopup` 供宿主确认真实原生能力。
- 增加 hover 的 observe_only 只读分支：已打开的面板无需先移动鼠标即可采集；拒绝混入输入目标或停留时间，绕开 root 接收者检查仅限观察，不放宽点击。
- 沿用 click 工具增加 popup_token：只接受弹层图片的局部像素坐标、global 左键单击。30 秒租约，其他工具/观察及会话结束失效；任意点击尝试消耗。
- 输入前再次检查根窗口前台与几何、弹层当前 PID/几何/可见性及实际 mouse-down 接收窗口，不抬升主窗口，不按同 PID 豁免遮挡。投递或回读失败报告未知结果，不回退或重放。

### Design Intent

同 PID、相邻位置是观察候选筛选，不能当作系统父子窗口证明。让模型看独立图片并显式选 token，输入仍绑定被观察的具体窗口；不把弹层坐标混进主窗口，也不增加模型工具数量。

### Validation

- Swift 定向回归覆盖捕获中 root/前台变化、候选移动或消失、AX 普通窗口排除、损坏图片、截图数量上限、元数据、缩放与负屏幕原点、过期/跨目标 token、实际接收者不匹配、输入未知结果不重放。
- 首次回归发现 CGRect.width 会标准化负尺寸，已改为检查原始 size.width/height，补强负尺寸用例。
- 原生最终定向验证：55 项 XCTest 与 6 项 Swift Testing 通过；新文件 strict SwiftLint 通过。已有 ForegroundHover 的六参数调度器存在默认 function_parameter_count 告警，未扩展其参数。
- Today helper 使用本地 fork 源码的临时包集成编译通过，未改持久 SPM pin，也未替换运行中 App。
- 真实 TextEdit/腾讯会议操作未执行；代码回归不能代表 GUI 选色成功。

### 复审与集成

独立复审发现已打开 popover 无法到达 hover 回读，已补 observe_only 和 Today app.observePopups；最终无新增 P1/P2。Today JS 34 项定向测试（含版本不匹配、metadata、跨绑定、迟到回包及 provenance）通过。正式 pin 在 fork 发布后同步，cloud 无需修改。
