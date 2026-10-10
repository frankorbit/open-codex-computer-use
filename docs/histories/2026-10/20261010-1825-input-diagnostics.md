## [2026-10-10 18:25] | Task: 关联坐标点击与原生输入诊断

### Execution Context

- Agent: Codex
- Runtime: Codex desktop

### 用户诉求

实际点击无效后补齐输入路径和坐标诊断，不能把函数返回等同于界面生效。

### 变更

- click 的 MCP 回执增加 `_meta.ocuDiagnostic`：随机 UUID、tool、returned/failed；不使用任意客户端请求 ID。
- 同步 TaskLocal 限定诊断关联范围，通过 OSLog notice 写入 `ai.today.ocu / input`，不依赖宿主 stderr。
- 记录窗口/PID/几何、截图到窗口和屏幕的坐标转换、AX 命中能力、选路、遮挡窗口，以及 SkyLight 事件步骤和实际延迟参数。
- 返回日志明确 effect=unverified，错误保持 unknown；不记录界面文字、App 名称、截图、用户参数正文或错误描述。
- 输入策略、授权门和失败不重放保持不变。

### 验证

- 216 项 Swift 非 GUI 回归通过；新增 MCP 错误关联、错误内容不入日志、逐调用 ID 和输入失败不重放测试。
- 真正第三方 App 的事件消费与状态变化仍待 GUI 验收。

- 独立只读复审无 P1/P2 阻断项；文档检查通过。
