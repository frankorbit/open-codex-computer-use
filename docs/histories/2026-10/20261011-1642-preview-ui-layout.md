## 2026-10-11 | Task: 修复本地画中画尺寸、边缘与交互反馈

### 用户诉求

画中画有细黑边，切换竖向计算器后过大且超出屏幕；鼠标移到边缘没有缩放提示。

### 实现与取舍

- `LivePreviewLayout` 统一比例、屏幕留白、最大/最小尺寸与拖拽锚点计算；切换目标保留长边尺度。自动布局高度一般限制为可用高度的 55% 且不超过 480 点，极小屏幕优先满足可容纳的最小尺寸。
- `LivePreviewPanel` 负责本地窗口样式、屏幕变动与尺寸约束。拖动结束后按当前屏幕重新收敛，跨 run 恢复默认尺寸。
- `LivePreviewView` 增加 8 点宽的边缘/四角命中区、方向光标和真实 resize 事件处理；内部拖动只移动预览，不转发给目标 App。
- macOS 15 及以上使用系统 frame resize 光标；macOS 14 使用系统横竖光标和本地绘制的对角箭头。
- 清除黑底，使用透明采集背景，图像直接绘制到已受比例约束的内容区，消除重复 aspect-fit 因像素舍入产生的留边。保留完整源帧，不猜测或裁切应用自身的边框。
- `LivePreviewCapture` 收纳原有预览采集配置和 sink；捕获目标、最新帧缓冲、身份校验及生命周期保持原逻辑。
- 输入期间的鼠标穿透继续保留；进入该状态时清理本地缩放手势，避免收不到 mouseUp 后残留交互状态。

### 边界与复审

- 改动仅在本地展示层。未改 `AccessibilitySnapshot`、MCP/JS 图片响应、截图导出、SkyLight 输入、前台切换或云端策略。
- 复审补齐了拖拽中显示器断开导致旧锚点不可用的恢复，以及小屏幕自动布局与最小尺寸冲突。
- 透明圆角和取整细缝已用像素测试验证；应用自身像素中已存在的边框不作破坏性裁切。
- 未执行目标应用 GUI 操作，未读取微信，未提交、推送或变更 Today pin。

### 验证

- `swift test --filter LivePreview`：12 项测试通过，包括参数化八方向命中/锚点、屏幕边界、超长竖屏、负坐标屏幕、断屏恢复、实际 NSView 鼠标事件、透明像素与四边填充、生命周期回归。
- `swift build --product OpenComputerUse`：通过。
- 变更文件 SwiftFormat 与 SwiftLint strict：通过。此 fork 没有 `justfile`，直接执行对应格式、lint 与 SwiftPM 构建检查。
- 主 App 的真实悬停、跨屏拖动和 ScreenCaptureKit 实时画面验收仍待完成；自动化组件测试不等于真实 GUI 验收。

### 关键文件

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewLayout.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewPanel.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewView.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewResizeCursor.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LivePreviewCapture.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LiveWindowPreview.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LivePreviewLayoutTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LivePreviewTests.swift`

### 本地 App 替换

用户随后明确要求替换运行的 App。本轮通过 SwiftPM 临时 editable dependency 编入未提交 fork 源码，完成 Today Canary arm64 Debug 构建；产物内保存 `OCULocalBuild.json` 和 helper 本地构建标记，远程 pin 仍为 `f62ac38`。构建时修复 ScreenCaptureKit 不持有 backgroundColor 的生命周期警告，改用进程生命周期常量持有透明色；12 项预览测试及格式/lint 检查再次通过。

主 App 与 helper 重新签名，deep/strict 验证通过；新 helper 符号确认包含布局和缩放光标实现。旧 App 正常退出，新 App 从同一 Canary 路径启动，已建立到 ocu-alignment 本地 18081 隧道的 TCP 连接，lane health 为 200。临时 SwiftPM override 已移除；未提交推送、未更改仓库 pin、未重新部署云端。后续普通构建会重新使用固定 pin，正式保留修复仍需发布 fork 并更新依赖。


### 后续纠正：恢复黑底与真实后台光标

用户复测要求恢复黑底，并指出缩放光标仍未显示。前版用 `.cursorUpdate + .activeAlways`，AppKit 明确不支持该组合；已有测试只直接调用鼠标处理函数，未验证真实悬停事件。此外，后台进程的 `NSCursor.current` 更新不代表系统可见光标更新：独立窗口实验确认不启用后台光标权限时二者不同。

- 恢复采集、panel 和 view 的黑色底衬，保留比例、尺寸约束和完整图像填充。透明源像素按黑色合成。
- 改用 `.mouseEnteredAndExited + .mouseMoved + .activeAlways`，窗口启用鼠标移动事件。
- 新增仅用于预览的 `LivePreviewCursorAccess`：动态解析 SkyLight connection property，仅在真实悬停/拖拽期间启用 `SetsCursorInBackground`；保存并恢复原来的缺省/false/true 值。退出、收起、窗口解绑或输入穿透时恢复，隐藏窗口的迟到移动事件不能重新获取权限。
- 私有 API 可能随系统变化；解析或调用失败会记录一次错误，不激活宿主、不移动指针、不阻断 agent 输入。能力只作用于当前 helper 连接，不修改目标应用或输入工具。
- 新增后台权限恢复、读失败、恢复失败重试和 tracking 配置回归；黑底像素及四边填充测试同步调整。
- `scripts/test-preview-hover.sh --move-pointer` 是显式 opt-in 的独立窗口验收。它只移动指针经过预览八方向和中心，比较 WindowServer 系统光标图像与期望光标，并校验前台 PID、非激活状态、连接属性恢复；结束恢复原指针位置。命令行 fixture 启动可能自动激活，因此在测试开始前先恢复原前台应用；验收采样期间不切前台。该脚本不纳入默认单元测试，也不操作其他应用文档。

参考：
- [Apple activeAlways 限制](https://developer.apple.com/documentation/appkit/nstrackingarea/options-swift.struct/activealways)
- [Ice 的 WindowServer connection property 封装](https://github.com/jordanbaird/Ice/blob/main/Ice/Bridging/Bridging.swift)

此处纠正前文的透明底方案与验收范围，不将此前的组件测试追认为真实悬停成功。


复审又捕获了重新进入的缓存问题：AppKit 在后台权限启用前缓存 resize cursor，再设同一个 cursor 会跳过系统更新。进入新的悬停周期后先置回箭头再设置目标 cursor，随后连续十次离开/进入校验系统光标；回归脚本保留该序列。窗口内部持续移动不重复开关连接属性。


最终复核还修正了验收脚本的产物来源：Xcode SwiftPM 的 executable build 不保证刷新 `libOpenComputerUseKit.a`，脚本现在链接本次构建的 `OpenComputerUseKit.o`，旧静态库试验不计入最终验收。新产物证实仅同轮异步重设仍存在跨进程光标覆盖；最终仅在真实悬停期间以 20 Hz 刷新，刷新前校验窗口可见、未穿透、物理指针命中同一窗口及内容区，离开/遮挡/收起/输入立即撤销 timer 与后台权限。正常无人悬停时没有此轮询，不采集截图、不移动系统指针、不激活应用。


### 本轮最终交付验证

- 15 项预览回归测试通过；SwiftFormat lint、SwiftLint strict、文档检查和 diff 空白检查通过。
- 使用当前 object 产物的独立非激活窗口完成 32 个系统光标/连接属性/前台身份检查，零失败，包括八方向、内部、离开、十次重复进入、输入穿透及收起清理。指针已恢复；没有操作目标应用内容。主 App 的完整 agent 场景、跨显示器拖动和旧版 macOS 仍不计为本次验收覆盖。
- 已重新编译 Today 的 OCU helper，更新当前 Canary App 的嵌入产物与本地构建回执，重新签名并通过 deep/strict 检查后重启。仅替换本地已授权 App；云端无变化。
- 临时 SwiftPM editable override 已移除，源码与正式 pin 未提交/推送，正式 pin 仍为 `f62ac38`；后续从固定 pin 重建会回到旧 UI，发布保留此修复需要另行更新 pin。
