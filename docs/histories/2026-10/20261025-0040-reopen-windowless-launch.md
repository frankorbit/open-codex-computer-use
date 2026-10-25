## [2026-10-25 00:40] | Task: 冷启动无窗口时后台补发一次 reopen

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 在 fork 里让 getApp 冷启动或 reopen 后等窗口超时、应用仍没有可用窗口时，在后台（不激活）补发一次 reopen 再等一次。补测试，用复现步骤真机验证。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`docs`

**Key Actions:**
- **`waitForOpeningWindow`**：初始化打开应用后的窗口等待抽成独立步骤。首轮 3 秒等待超时（探测未见可用窗口）时，校验仍是同一进程，复用同一个打开请求在后台（`activates = false`、不新建实例）补发一次 reopen，再等一轮；reopen 返回其他进程时报错、不继续绑定。最多补发一次，挂起期间再次初始化仍不会再打开。
- **超时消息**：`applicationWindowTimeoutMessage` 说明两轮等待（含一次后台 reopen）都未就绪，前缀不变，Today 的错误分类与重试判断不受影响。
- **测试**：`ApplicationWindowWaitTests` 覆盖补发后就绪成功、首轮就绪不补发、reopen 返回其他进程即停止、两轮都超时后保持挂起且不再打开。
- **文档**：`docs/ARCHITECTURE.md` 窗口就绪等待一段补充后台 reopen。

### 🧠 Design Intent (Why)
真机复现：Numbers 处于没有可见窗口的状态（例如“打开”面板点了取消）时被强制结束，之后后台冷启动会恢复成无窗口状态（只附带一个隐藏的颜色面板），不弹出“打开”面板；收到 reopen 后 0.6 秒内显示。原先超时后禁止再次打开，后台模式又不能激活应用，模型只能拿到 `cgWindowNotFound` 并放弃。修复后同样的复现步骤，一次 `get_app_state initialize:true` 用 4.8 秒返回“打开”面板，前台应用保持不变。补发只在首轮等待未见可用窗口后进行：已有窗口时 `activates = false` 的 reopen 可能把应用切到前台。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ApplicationWindowWait.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/ApplicationWindowWaitTests.swift`
- `docs/ARCHITECTURE.md`
