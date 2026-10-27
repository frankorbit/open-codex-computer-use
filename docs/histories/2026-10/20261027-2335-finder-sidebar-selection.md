## 2026-10-27 23:35 | Finder 侧栏单次选择

### 用户诉求
继续逐题实机验收，遇到失败先根因修复；不重放已发送操作或放宽停止规则。

### 证据与实现
Finder 侧栏 Documents 已实际导航，但后代 AXOpen 返回 -25205。现有 AXList 选择不覆盖 AXOutline 行。Codex 对独立 Desktop 行单击成功，具体底层路线未知。

新增严格限于 Finder sidebar 原始行目标的 AXSelectedRows 路线，单次发送，能力失败或发送后失败不回退。prepare 复验父链与绑定窗口；真实权限保持 permissionDenied。普通控件、其他 outline、网页、双击右键保持不变。

### 验证
helper 注入测试与真实 ComputerUseService.click 入口测试覆盖选择次数、失败不回退；完整串行672 XCTest（8跳过）+68 Swift Testing通过，新增文件格式lint通过。独立review指出的权限分类与读取预算问题已补齐；既有输入预算与停止规则不变。原 Documents 操作不重放，新签名App另选尚未发送的侧栏目标验收。
