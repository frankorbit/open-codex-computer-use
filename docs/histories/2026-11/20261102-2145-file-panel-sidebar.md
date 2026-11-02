## 2026-11-02 | Task: 修复系统文件面板侧栏单击

### Execution Context
- Agent: Codex desktop，当前对话内实现与复审。

### 用户诉求
> 开始修复 Today。保留错误停止和禁止重放约束。

### 根因与设计
TextEdit 保存面板侧栏单击落入后代 AXCell 的 AXOpen，导航已发生却返回 -25205。原有 AXSelectedRows 选择路径仅限 Finder。Codex 对照同类点击成功，但其内部动作不可见，不能据此断言两者底层实现相同。

扩展已有选择语义到明确识别的 AXWindow/AXSheet（open-panel/save-panel）。仅原始侧栏行、左键单击、非网页有效；普通 outline、后代标签、双击、右键和显式鼠标路径保持原行为。

发送前与能力检查共用既有 350ms 预检预算，实时核实面板身份、同进程父链、每级父子挂接、可见性及绑定窗口。缺失/歧义/陈旧/跨窗口/隐藏/网页目标拒绝输入。选择 setter 只执行一次；任何发送后失败均终止，不转 AXOpen 或鼠标，不以导航已变化掩盖错误。

### 关键文件
- `AXFilePanelSidebar.swift`：面板识别、实时范围校验及发送前准备。
- `AXSidebarSelection.swift`：复用选择契约，保留能力、权限和错误传播。
- `ComputerUseService.swift`：普通元素单击入口的窄范围分派。
- `AXFilePanelSidebarTests.swift`、`AXSidebarSelectionTests.swift`、`FinderSidebarClickServiceTests.swift`：范围变更、错误、一次发送及非适用路径回归。
- `docs/ARCHITECTURE.md`：同步适用范围。

### 验证与复审
- 完整原生测试：744 项 XCTest，8 项跳过，0 失败；77 项 Swift Testing 通过。
- 当前 Xcode SDK 与宿主系统运行库存在已确认的不匹配，使用已验证的 macOS 27.0 SDK/native build system 跑测试，未改项目工具链或正式构建配置。
- 新增/相关小文件 SwiftFormat、SwiftLint 通过；大型 ComputerUseService 的既有 94 条 lint 诊断仍存在，没有新增诊断项，文件/方法长度统计随本次代码增加。
- `git diff --check` 通过；仓库无 justfile。
- 复审确认只新增文件面板侧栏分支，不改变菜单截图、超时规则、取消、停止规则或云端代码。

### 验收边界
本轮为源码和自动化测试通过，尚未提交推送、更新 Web native pin 或编译新签名 App。当前运行的 Today 不含本次改动。第5题必须用新签名 App 从新观察开始验证 Documents/Desktop 导航、纯文本保存和 Finder 回读；不得覆盖 Codex 对照产物，也不得把 Codex 成功计作 Today 验收。
