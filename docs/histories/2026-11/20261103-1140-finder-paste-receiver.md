# Finder 文本粘贴接收者保护

用户要求继续修复第6题中新建文件夹后粘贴名称生成 Text Clipping 的问题。

## 证据与判断

- 原始 trace 确认新建后输出了 selected text，粘贴后焦点为 ListView；只有一次 paste 请求，三张 PNG 未移动。
- 旧 paste_text 只验证进程及窗口，并允许通过应用菜单 Paste 提交。Finder 文件列表也消费文本粘贴，因此窗口正确不等于编辑接收者正确。
- 尚不能从旧诊断确定失焦发生于准备、菜单动作还是外部交互；旧 paste_text 没有输入诊断关联 ID。没有将此次现象归因到上一轮 selection 观察改动。
- Codex 独立目录导航未成功确认，因此没有把它计为命名粘贴对照通过。原下载目录产物保留，未重发创建、粘贴、移动或删除。

## 改动

- ComputerUseService 根据已解析的 bundle identity 只对 Finder 的文本粘贴要求实时可编辑接收者，准备前捕获、提交前复验同一 AX 身份和窗口；不使用缓存 selected text 授权。
- Finder 文本粘贴通过已验证的 PID Cmd+V 路径提交，不调用文件管理菜单 Paste。其他应用仍保留无 AX 文本焦点的兼容路径；press_key 的文件复制与移动、type_text、set_value 的路由不变。
- 入口和事务校验检查取消。提交前失焦恢复仍由 ClipboardInput 所有权事务负责；一旦尝试提交，错误保持未知、保留新剪贴板内容，不换路或重放。
- MCP 为 paste_text 添加与键盘工具一致的诊断关联 ID；阶段日志仅记录固定 route 字段，不记录文件名、文本或剪贴板内容。
- 同步工具说明、REPL说明与架构文档；新增 FinderPasteReceiverTests，扩展 Runtime 与诊断测试。

## Review

没有改点击机制、焦点等待值、菜单焦点生命周期、超时阈值、权限分类或停止规则。新增限制仅针对 Finder 的纯文本粘贴：AX 编辑者不可确认时会在提交前拒绝，这不能被视为已完成命名，也不能自动回退到其他输入。

## 验证

- XCTest 最终完整运行：763项、8跳过、0失败（新增9项）。
- Swift Testing 显式串行：77项通过。默认并发完整运行仍有 quiet focus release 计时断言失败；该类型在前轮也出现，但本轮未做干净HEAD因果对照，不将默认完整运行记为全绿。
- Runtime 全套51项通过；最终工具定义、Finder入口和MCP诊断回归17项通过。
- 新增文件与接收者小文件 SwiftLint 通过；大型旧文件存在既有结构/风格诊断，没有做无关重构。仓库无 justfile，使用 Swift tests、SwiftLint、SwiftFormat、文档检查及 diff check。
- 文档骨架及 diff check 通过。repo-hygiene 因基线缺少 .editorconfig、若干 .github 模板/工作流与 .markdownlint.json 未通过；git ls-tree 确认这些文件不在当前 HEAD 中，未为本修复创建无关模板。
- 本轮未提交、推送、更新Web pin或重编签名 App；新代码的 Finder 真机命名与第6题完整验收尚未通过，见进行中的执行计划。
