# 会话级后台执行约束

## 问题与目标

Today 的后台启动与自动点击默认不足以约束完整任务：旧宿主仍启用显式前台点击和 hover，agent 遇到输入失败可自行切换真实鼠标路径。另有一次实测前台切换早于首次 global 点击，尚不能把根因全部归到显式前台回退。

本轮将 Today helper 固定为后台执行模式，由原生 service 与 JS 入口共同限制前台路径；保留 AX、SkyLight 和后台键盘。增加合成焦点分阶段诊断，清理失败不得静默忽略。没有观测到效果时先重新观察，不能重放未知发送。

## 范围与约束

- fork：`OPEN_COMPUTER_USE_EXECUTION_MODE=background` 覆盖旧前台开关；未设置时保留独立上游使用方式。
- Today：宿主设定模式，普通工具调用不得升级；cloud 指导使用新截图中的后台坐标聚焦和输入读回。
- 不强行恢复用户的前台或真实鼠标位置，不将这种事后恢复包装成后台执行。
- 不承诺所有目标 App 自身都不会主动激活；新增诊断用于区分执行层与目标 App 行为。
- 不发布新 revision、不更新 pin 到不存在的提交、不部署 lane；本轮验证源码与本地集成。

## 进度

- [x] 复核 trace 与 Codex 后台操作样本的证据边界。
- [x] fork / native / cloud 实现与自动化回归。
- [x] 独立复审、修复发现、再次验证。
- [x] 记录交付边界和剩余真实 App 验收。

## 验证

执行策略必须在发送事件前拒绝前台请求。覆盖错误配置、旧环境变量覆盖、元素与坐标点击、键盘接收者变化、未知输入不重放、合成焦点清理失败。真实 App 验收与单元测试、本地依赖 override 构建分开记录。

## 最终验证与复审

- fork 全量 XCTest 364 项，7 项 opt-in live 跳过、0 失败；另 12 项 Swift Testing 通过。
- Today Node 全量 49 项、cloud OCU prompt 41 项通过。Today Swift 本地新 fork override 为 40+29 项；既有异步交接测试一次时序失败，单项与整包复跑均通过，生产交接代码未改。
- SwiftPM 的 `--disable-automatic-resolution` 会恢复旧 pin，不能用该次测试声称新 fork 集成。重新 edit 后使用 `--skip-update`，核实实际编译源路径、workspace-state 的 edited 路径及 helper 中的新策略实现；源码摘要在验证前后不变。结束后 unedit，移除临时链接，未修改 pin。
- 实际 TodayOCUHelper MCP 进程在严格后台模式中，即使旧 foreground/hover 开关为 1，global 点击与实际 hover 仍在目标查找前拒绝。
- 隔离 Chrome 实测：3 次后台点击及 3 次后台键盘输入全部成功，操作后前台和指针检查通过。另用独立 50ms 采样监测执行区间，29 个样本中前台保持 Codex、鼠标位置唯一；采样不能排除采样间隙的极短变化。
- 两轮独立审查及补充跨层复审，发现的逐块校验、统一策略解析、只读 popup 门禁、后台候选采集和错误指导均已修正；最终未发现新增有证据的 P1/P2。

## 交付状态与后续验收

本轮源码与本地集成闭合，尚未提交、推送、更新 native pin 或部署 lane。下一步交付顺序为 fork revision、Today pin/manifest、主 App 构建，再部署 cloud lane；不能将旧 App 的行为当成本轮代码结果。

飞书真实任务需重新验证 AX 点击、后台坐标聚焦、文本输入和发送效果，并检查分阶段诊断。早于首次 global 的前台切换尚未由新 trace 定位，不宣称目标 App 的主动激活问题已全部解决。前台 hover、global popup 点击和无法确认接收窗口的 PID 拖拽在本模式中不可用；只读 popup 与验证后的后台滚轮保留。
