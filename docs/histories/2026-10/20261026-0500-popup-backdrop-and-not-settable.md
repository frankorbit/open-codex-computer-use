## [2026-10-26 05:00] | Task: 弹层截图保留材质底色，set_value 不可写报错说明出路

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code desktop (macOS)`

### 📥 User Query
> 预览里的弹窗显示成黑色；提醒事项日期改不了。按通用方式修：不可写元素的报错说明角色和出路，弹窗截图显示正常。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **弹层截图（概览与实时预览）**：按显示器过滤、只包含弹层和它的主窗口并裁剪到弹层位置，底色用跟随系统外观的窗口背景色；再用硬件缓冲区里弹层自身的透明度做蒙版（`PopupWindowImage.masked`），圆角外与不可见的辅助窗口仍透明。弹层不在屏幕上或跨屏时退回硬件缓冲区。
- **`set_value` 不可写报错**：`nonSettableSetValueErrorMessage(elementIndex:role:)` 说明元素编号与角色，指出开关、复选框、按钮要用点击改变，只以文字显示的值需先打开它的编辑器；前缀不变。
- **测试**：蒙版保持弹层形状与半透明比例、底色随外观且不透明、不可写报错文本。

### 🧠 Design Intent (Why)
弹层的半透明材质在渲染时与背后内容混合；只截弹层或读硬件缓冲区时背后没有内容，合成为不透明深灰（实测 RGB 71、alpha 255），事后无法还原，预览与交给模型的图都像一块黑板。连同主窗口渲染只修好盖在主窗口上的部分，伸出主窗口的部分仍是深灰；带上桌面层会截到壁纸和桌面图标，不可接受。用外观底色渲染后整块材质与屏幕一致，但底色会填满圆角外和不可见的辅助窗口，实时预览依赖透明度识别后者，所以再按弹层自身的透明度裁回。

提醒事项实测：日期行折叠时树里没有日期控件，模型把日期 set_value 到日期开关上，只得到 “not settable”。真机确认：后台点日期文字或 “Date” 标签不能展开编辑器，切一次开关（关再开）会展开日期框并把日期重置为今天。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/PopupWindowImage.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupWindowCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HoverPopupSystemCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewPopupCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LivePreviewPopupRenderingTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
