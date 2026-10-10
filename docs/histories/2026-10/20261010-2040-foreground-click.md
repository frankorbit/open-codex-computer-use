## 2026-10-10 | Task: 区分后台 AX 与前台鼠标点击

### Execution Context

- Runtime: Codex desktop

### User Query

> 坐标点击使用已验证可行的前台路径，同时避免计算器等支持 AX 的应用被所有操作强制带到前台。

### Changes Overview

- 新增点击专用环境策略，保留全局滚动、拖拽原有配置。
- `auto` 命中直接 AX 控件时继续后台动作；需要鼠标时使用精确窗口准备后的 HID 点击。
- 前台准备前仅验证窗口身份与几何，准备后验证焦点、几何、Space 和遮挡；不自动重放输入。
- 普通观察禁用自动激活恢复，冷启动使用非激活配置；只对明确无窗口错误短暂只读重试。
- 独立复审发现激活前同 App 遮挡阻止准确窗口抬升，已拆分前后校验并补回归。

### Design Intent

保留有效的后台能力，将会移动真实指针和改变焦点的行为限制在需要鼠标的点击路径。事件发送返回不代表应用消费成功，调用方仍须读取实际界面。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateClick.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateWindow.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CoordinateClickTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CoordinateWindowTests.swift`

### Validation

- 最终 226 项非 GUI 回归通过，覆盖后台启动配置、观察重试边界。
- 复审补丁后 22 项前台点击/窗口校验定向回归通过。
- 真实腾讯会议与普通聊天全链路需要使用新的固定版本再验收；本轮不创建会议。

### 深度复审后的修正

- 修正元素 AX 未知回执仍继续候选和 HID 的缺口；重复动作部分成功后失败也立即停止，AXOpen unsupported 不再视作成功。
- 前台遮挡从窗口矩形推断改为 AppKit mouse-down 实际接收窗口，保留身份、几何、前台及 on-screen 核验；无 Dock/helper 进程白名单。
- 缓存按目标统一关联别名；观察失败使所有别名失效，只有完整成功的显式观察发布快照。输入缓存缺失不隐式刷新，动作回读只读；窗口放置和最终观察失败均不保留中间快照。
- 删除不再使用的动作回读策略函数，以真实 service 调用链回归替代常量断言。
- 最终 252 项非 GUI 回归通过（Kit 249、cursor support 3）；新增文件 SwiftLint strict / SwiftFormat 检查通过。Today 本地 fork 集成 helper 编译通过，运行时及 hover 测试 66 项通过。
- Today `just check` 在撤销 SwiftPM 临时映射后通过；使用现有 nvm Node，避开本机 Homebrew Node 缺少 llhttp 动态库的问题。
- 文档骨架检查通过；通用 `make check-repo` 因 HEAD 已缺少的 editorconfig、工作流及 issue 模板等文件失败，未扩展修改这些仓库模板。
- 临时 SwiftPM edit 已撤销；远程依赖仍为旧 pin。未提交、推送或替换运行 App，真实腾讯会议和计算器体验仍待发布后的 lane 验收。
