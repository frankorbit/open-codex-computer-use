# 保留正在编辑的未选中行

用户要求按顺序完成真机回归，失败对照Codex、查明原因修复，禁止重放已发送操作或放宽停止规则。

提醒事项编辑标题时行不一定被AX标为selected，既有renderer摘要规则把编辑控件一起隐藏。本次新增只读、有界且锚定当前窗口/PID的焦点祖先路径，仅保留该路径上的行内容。其他行仍摘要，节点与深度限制不变，输入分发和错误策略不变。

相关文件：`AXFocusedRowPath.swift`、`AccessibilitySnapshot.swift`及`AXFocusedRowPathTests.swift`。定向8项已通过；完整回归、签名制品与实机结果见对应execution plan，不把本次修复记为菜单观察问题或整道提醒事项题已解决。
