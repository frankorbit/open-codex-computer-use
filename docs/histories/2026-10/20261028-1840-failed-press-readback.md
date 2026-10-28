## 2026-10-28 | AXPress 失败后的只读证据

### Execution Context
- Agent: Codex / desktop

### User Query
继续修复失败后的证据缺失，保持停止与禁止重放规则，验收后继续复测。

### Changes Overview
普通原始按钮的单次 AXPress -25200 通过内部类型携带原错误。ComputerUseService 只读构建同一绑定窗口的诊断，始终返回 isError；不调用输入、不恢复窗口、不发行输入凭证。诊断失败不覆盖原错误。其他错误和输入路径不变。

完成但未捕获候选的弹层观察明确标记 completed，继续保留范围限制及无 token 边界。

### Design Intent
真实 AX 返回失败不代表未执行；已观察到错误返回后详情打开。证据用于解释，不将错误升级为成功，不重发动作。

### Validation
Swift MCP 入口覆盖改变/不变、观察失败、窗口/进程变动、权限/超时、取消、成功路径和旧索引失效。Web 对应适配另测 owner-guard、迟到输出与错误结算。实机新包验证另记，不能以单元测试代替。

本轮完整串行测试 707 XCTest（8 跳过）和 68 Swift Testing 通过；新增文件与 AX 执行文件 strict SwiftLint 通过，git diff --check 通过。make check-docs 通过；make check-repo 的卫生检查仍因 HEAD 已缺少 .editorconfig、PR/issue/workflow 模板等文件而失败，不在本轮补无关模板。
