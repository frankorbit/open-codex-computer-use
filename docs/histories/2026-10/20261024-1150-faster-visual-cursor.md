## [2026-10-24 11:50] | Task: 虚拟光标动画时长减半

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 把虚拟光标移动的速度加快，时间搞短一点，减少一半的时间。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **移动时长减半**：`OfficialCursorMotionModel.calibratedTravelDuration` 返回还原的弹簧收敛时间乘以 `travelTimeScale`（0.5），每次移动约 1.43 s 降到约 0.71 s；弹簧曲线与路径选择不变，只是以两倍速度播放。
- **点击脉冲减半**：`SoftwareCursorOverlay.clickPulseDuration` 0.16 s → 0.08 s，多击之间的间隔 `clickPulseGap` 0.05 s → 0.025 s。
- **测试**：更新移动时长断言，新增减半常量断言。

### 🧠 Design Intent (Why)
光标动画在主线程上同步播放，每次点击都要等动画结束才发送输入，约 1.6 s 的固定开销会叠加到每一步操作。动画只用来提示输入落点，减半后仍能看清移动轨迹，同时显著缩短单步耗时。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CursorMotionModel.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorOverlay.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
