## [2026-10-26 03:10] | Task: 弹层内控件可查、可点，set_value 支持日期

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 按元素点击且目标元素位于同一应用的弹窗里时，遮挡校验把承载该元素的弹窗当作接收窗口；set_value 支持日期值；用提醒事项详情弹窗里的日期框真机验证，一起提交。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`docs`

**Key Actions:**
- **承载弹层（`CoordinateReceivingWindow`，新增）**：按元素点击走坐标回退时，取点击位置上、主窗口之上、同进程、屏上可见的最上层窗口；该点的 AX 命中结果与目标最近的共同祖先是目标本身或整个落在该窗口内时，它就是承载目标的弹层。遮挡校验把它当作接收窗口（其他同进程窗口仍拦截，弹层变化或关闭即拒绝，点击位置可伸出主窗口），`sky_click` 投给弹层、使用弹层局部坐标与 `popup` 配置（不重新设 key）。
- **`set_value` 日期（`SetValueConversion`，新增）**：当前值是 CFDate 时，按本地时区解析 `2026-10-26` / `2026-10-26 10:00` / 带时区的 ISO 8601，写入 CFDate；只有日期时保留原时刻；解析失败报说明清楚的错误、不写入。其他类型照旧写字符串。
- **query 可见范围**：与窗口相交才算可见；`AXPopover` 本身可见，其子树按弹层范围判断（`targetedNodeVisibility`）。按编号操作前的位置复核同样按所在弹层范围判断。
- **测试**：`CoordinateReceivingWindowTests`、`SetValueConversionTests`、`TargetedQuerySafetyTests` 新增用例；工具说明与 `targeted-query` 文档同步。

### 🧠 Design Intent (Why)
提醒事项详情弹层在 AX 树中挂在主窗口下，在 WindowServer 中是盖住并伸出主窗口的独立窗口。原先：弹层里不支持 AXPress 的控件点击被弹层自身判为遮挡；伸出主窗口的控件被 query 当成不可见、按编号操作时位置复核失败；日期框的 AXValue 是 CFDate，写字符串被以 -25201 拒绝，后台点击也不能让日期框获得键盘焦点。

真机（提醒事项「打印登机牌」详情弹层，后台模式，前台应用不变）：query 按 `date time area` 找到伸出主窗口的日期框；按编号点击走承载弹层并成功投递（同一路径点击 Notes & URL 后焦点移到备注框）；`set_value "tomorrow"` 被拒绝且未写入，`2026-10-27`、`2026-10-26` 依次写入并读回一致，界面显示 10/26/2026。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateReceivingWindow.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SetValueConversion.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateWindow.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/CoordinateWindowQuery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/TargetedQuery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CoordinateReceivingWindowTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SetValueConversionTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/TargetedQuerySafetyTests.swift`
- `docs/targeted-query.md`
- `docs/targeted-query.zh-CN.md`
