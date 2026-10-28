# 2026-10-28 实时预览主窗口隔离

用户反馈提醒事项详情在本地预览重复、缩放错位。真实窗口只见一个详情；既有主窗口流使用 desktop-independent 过滤，系统可连带输出子窗，随后本地再次叠加独立 popup，形成重影风险。

可见且完整位于一块显示器内的 root 改用只包含精确窗口 ID 的 display-bound 流，关闭 includeChildWindows，按显示器本地坐标裁剪，不采桌面或其他 App。监控窗口平移、大小、显示器及可见性变化，撤销旧裁剪帧。跨屏、部分离屏、隐藏或其他 Space 仍保留独立流与等比画面，但不再额外叠加 popup，不显示未经证实映射的虚拟光标。该退回路径可能有等比留边，不承诺窗口组可映射到 root 坐标。

未修改模型图片、输入 token/坐标、点击实现、观察预算、权限/取消/超时/停止规则。生产范围为 LivePreviewCapture、LivePreviewRootCapture、LiveWindowPreview。没有自动重放输入。

验证：710 项 XCTest（8 跳过）和72项 Swift Testing 全过，新增4项覆盖精确裁剪配置、负坐标多屏、跨屏/隐藏退回、移动旧帧拒绝以及合成策略。SwiftFormat及SwiftLint执行；仅LiveWindowPreview既有文件长度警告（原408行，现416行），无新增行级警告。diff-check通过。尚待更新宿主pin、签名App实机对照，不能把自动测试当作重影已消失。
