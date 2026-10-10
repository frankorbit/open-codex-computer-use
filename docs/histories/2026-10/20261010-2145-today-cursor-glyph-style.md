## [2026-10-10 21:45] | Task: 为软件光标增加可选 Today 样式

### 🤖 Execution Context
- **Agent ID**: Codex
- **Base Model**: GPT-6
- **Runtime**: Codex desktop / 本地 SwiftPM

### 📥 User Query
> 在当前 main 直接增加独立的 Today 品牌色光标样式；仅允许修改 renderer、新增样式文件、相关测试和独立 history。保留上游默认样式、参考图与运动，不触碰并行 PiP 工作，不运行 GUI、commit、push 或分支操作。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit` 的光标绘制层。

- 在实际执行绘制的进程设置 `OPEN_COMPUTER_USE_VISUAL_CURSOR_THEME=today`，启用 sRGB `(0.01, 0.66, 0.96)` 和 `0.35` 光晕强度；忽略大小写及首尾空白。未设置、空值或未知值均保持上游样式。
- 每次绘制读取主题；派生参考图首次使用时生成并缓存。参考图中 alpha ≤ 0.65 的区域衰减到 0.35，alpha ≥ 0.90 的区域保持原透明度，中间平滑过渡。预乘 RGBA 同比缩放，原始图片及文件不变。
- 使用独立透明合成层着色，保留背景和绘制状态。资源缺失或派生图生成失败时沿用程序化回退；回退光晕在原有动态范围限制后乘以 0.35，避免下限抵消淡化效果。
- 不改变窗口尺寸、tip anchor、轮廓数据、参考图变换或运动计算。没有修改 Overlay、Service 或 Package.swift，也没有新增配置转发、会话保持或 PiP 行为。

### 🧠 Design Intent (Why)
复用旧 Today artwork 的品牌色、透明度平滑过渡和隔离合成方法，把可选样式限制在 glyph 绘制边界。保留现有三参数绘制入口，并增加可注入样式和参考图的内部入口，用于无窗口的位图测试。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorGlyphRenderer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorGlyphStyle.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SoftwareCursorGlyphStyleTests.swift`
- `docs/histories/2026-10/20261010-2145-today-cursor-glyph-style.md`

### 验证与边界
- 默认环境：`env -u OPEN_COMPUTER_USE_VISUAL_CURSOR_THEME swift test --filter 'SoftwareCursorGlyphStyleTests|OpenComputerUseKitTests.testSoftwareCursorGlyph'`，11 项通过。
- Today 环境：`OPEN_COMPUTER_USE_VISUAL_CURSOR_THEME=today swift test --skip-build --filter 'SoftwareCursorGlyphStyleTests|OpenComputerUseKitTests.testSoftwareCursorGlyph'`，11 项通过。
- 包含 7 项新增离屏测试和 4 项既有 glyph 测试：环境选择、sRGB 常量、光晕阈值、本体透明度、原图不变、背景隔离、移动时 alpha 几何、绘制状态恢复、程序化光晕和真实绘制入口的环境选择。
- 新增两个 Swift 文件通过 SwiftFormat 0.60.1（`--swift-version 6.2 --commas inline`）及 SwiftLint 0.63.2 严格检查。
- Renderer 的 SwiftFormat 检查保留已有格式，禁用 `redundantMemberwiseInit,modifierOrder,trailingCommas` 三项规则后通过。SwiftLint 与 HEAD 源文件对比仍为原有 13 项，按规则、原因和严重程度比较没有新增问题；没有为清理旧格式扩大改动。
- `git diff --check` 通过。仓库没有 `just check`。
- 测试只使用内存位图，没有启动 App、窗口或 GUI 自动化。构建和测试通过不代表真实 App、环境转发、PiP 或 GUI 验收。
- 工作区同时存在其他执行者的 PiP 改动；本任务未写入这些文件。没有 commit、push 或分支操作。
