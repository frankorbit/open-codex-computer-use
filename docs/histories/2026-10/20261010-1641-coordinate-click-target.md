## [2026-10-10 16:41] | Task: 修复坐标点击目标选择

### Execution Context

- Agent: Codex
- Runtime: Codex desktop

### 用户诉求

创建可维护 fork，修复坐标点击导致错误窗口动作的问题，供宿主按 revision 集成。

### 改动与原因

- 坐标 auto 从实时 AX hit test 获取直接目标，不再沿窗口子树搜索可点击控件。
- AX 目标必须属于当前 snapshot 窗口且控件框包含点击点；未知窗口拒绝输入。
- 非 AX 控件、右键无 ShowMenu、多击和中键沿现有鼠标路径执行。
- 已发出的 AX 动作出现错误不再回退鼠标，避免重复效果。
- hit test 接受明确的窗口局部坐标，仅叠加窗口原点，不再次应用截图比例。
- 保留 element_index 的语义点击、显式方法和全局指针开关。

### 验证边界

- 新增 12 项回归；包含真实 `ComputerUseService.click(x/y)` 入口的截图缩放、窗口容器和命中失败测试。Swift 非 live 194 项、Node 30 项通过。
- 测试直接调用生产派发函数及 service 入口，注入 OS 查询/输入边界，未使用 fixture 点击捷径。
- `make check-docs` 通过；`make check-repo` 因上游基线缺少 `.editorconfig`、CI 模板等 11 个文件失败，未补建无关发布工作流。
- 第三方 App 的真实点击和截图回读仍需集成后人工验收；自动测试未操作用户 App。

### 关键文件

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateClick.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CoordinateClickTests.swift`
