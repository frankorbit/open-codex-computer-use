## 2026-10-27 23:05 | 修复无 AppKit 启动时间的进程身份校验

### 用户诉求

继续 Computer Use 真机复测；遇到问题定位根因并补回归，不重放已发送操作或放宽停止规则。

### 改动与原因

- Finder 存活但 `NSRunningApplication.launchDate` 缺失，初始化打开窗口后被错误拒绝。
- 新增内核 PID/启动秒/微秒身份读取，descriptor 构造时固定捕获，后续不按 PID 晚绑定。
- 保留原 AppKit 对象存活、PID、完整内核记录校验；读取失败、PID 复用仍拒绝。
- 初始化后的错误改为“未发送后续输入，不重放上一步”，避免误导调用方认为打开从未发生。
- 新增身份读取和完整初始化入口回归，已有身份变化测试迁移到原始整数时间。

### 主要文件

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SnapshotProcessIdentity.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppSnapshotCache.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SnapshotProcessIdentityTests.swift`

### 验证边界

针对性 37 项通过；全量串行 648 XCTest（8 skipped）和 68 Swift Testing 通过。新增文件 SwiftFormat/SwiftLint 通过；旧文件保留既有 lint 告警。并行预览计时测试的调度失败与实机待验收边界记录在执行计划中。此次不修改全局输入或权限策略。
