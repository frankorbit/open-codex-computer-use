# 输入策略与上游对齐

- 参考上游 3cfe4b1；保留前一轮未提交的 AX 独立输入与 paste 改动。
- 移除仅因目标自行进入前台而停止的规则；不增加主动激活或全局指针输入。
- AX 可选查询不可用允许进入窗口验证后的定向输入；权限/参数错误和动作未知结果仍失败。
- app_post 不统一要求系统前台或 AX focused window；已知窗口不匹配仍拒绝。
- 保留 Today 后台优先 auto、光标输入语义、生命周期、预览与结果未知不重放策略。
- 验证：正反单元测试、上游差异审查、Swift/JS 回归、本地依赖 override 集成、Today just check。
- 不提交/推送/更新远程 pin/部署，不恢复微信自动化；真实 GUI 验收单独记录。

## 完成与验证

- 三处阻断和对应错误断言已修复；后台 app_post 去除强制系统前台和强制 AX 焦点条件。
- 复审补上 app_post 可选 AX 查询后的窗口复验；已前台的 sky_key 路径也在发送前验证目标。
- 不在输入后重新套用“输入前窗口必须存在”条件，避免 Cmd+W 等合法关闭窗口被误报为未发送。
- 完整 Swift：382 项 XCTest，7 项 opt-in 跳过，0 失败；另 12 项 Swift Testing 通过。
- 最后仅整理测试文件/格式，相关 41 项回归通过；新增测试覆盖权限拒绝、窗口变化、无 AX 降级与未知结果不重放。
- fork Node 43 项、Today Node 87 项通过；Today helper 本地 override 编译及 just check 通过，override 已移除。
- 核心三文件字节对齐脚本通过。helper 有既有 SoftwareCursorGlyphRenderer nonisolated(unsafe) 警告，未改该功能。
- 源码复审未发现新增阻断项。GUI、后台实际接收与前台/鼠标副作用仍待独立验收；组合测试不替代桌面实测。
- 未提交、推送、更新 pin 或部署。
