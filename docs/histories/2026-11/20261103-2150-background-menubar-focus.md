## 2026-11-03 | Task: 补齐后台原生菜单栏的窗口焦点准备

### Execution Context
- Agent: Codex
- Runtime: 本地 macOS 工作区

### 用户诉求
继续修复 Numbers 已输入但 Save 不可用的问题，保持停止规则，不重放已发送的操作。

### 变更
- `AXMenuBarFocus.swift`：只为后台未展开的原生菜单栏单击准备绑定文稿的 key 状态，复用已有合成焦点、菜单租约与串行锁。
- `ComputerUseService.swift`：在普通 AX 候选派发前选择上述路径；AXPress只执行一次，失败不回退。
- 新完整 MCP 入口/AX属性回归及既有焦点租约集成回归。

### Review 与验证
- 不修改保存命令、业务字段、全局点击、键盘派发、Escape、取消、权限或超时规则。
- 前台菜单、普通控件、菜单命令和已展开菜单保持原路径；能力不可用时在输入前保留原AX路线。
- 准备前后验证原生菜单栏归属、启用/选择状态、窗口身份及几何；未知状态停止。不能因为AXPress返回success就报告保存完成。
- SDK26.5串行793项XCTest（8跳过）与77项Swift Testing通过。默认SDK/并发计时的既有环境限制未修改。
- Codex本次对同一文稿展开File后AX返回Save可用，但截图不可用；不同时间对照不能证明唯一根因或闭源实现。
- 尚未提交、更新Web pin或构建新签名包；Today保存及重开验收仍待验证，现有文稿未重发输入。

详见[执行计划](../../exec-plans/active/20261103-background-menubar-focus.md)。
