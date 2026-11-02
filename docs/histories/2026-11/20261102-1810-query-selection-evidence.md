# 查询保留菜单选择证据

用户要求继续 Computer Use 实机回归并修复问题，禁止重复执行已发送操作或放宽停止规则。

日历 Repeat 对照中，Codex AX 可读到 Every Week 的 selected 状态，而 Today query 只返回菜单标题等字段。定位到 query 的批量属性读取和紧凑结果序列化均缺少选择证据。

- 在同一次批量 AX 读取中加入 AXSelected 和 AXMenuItemMarkChar，不新增输入或轮询。原有批量失败降级路径会多读取这两个属性，仍受原查询预算约束。
- 保留原始布尔值及有界菜单标记；缺失、AX 错误和错误类型不推断为 false。
- 保留跨查询索引注册的数据，普通无属性结果结构不变。
- Swift 回归覆盖 true/false/未知/AX错误与序列化；宿主 Runtime 完整入口覆盖 query/find 透传、零输入，并保留原取消、超时及禁止重放回归。

此修复不宣称解决弹层截图不完整，也不把已有日程的只读核验记为创建流程端到端通过。

## 验证

- Swift 735 项 XCTest（8 项跳过）与 77 项 Swift Testing 通过；Runtime 283 项、fork REPL 50 项通过。新增文件 lint/format 和文档检查通过。
- 本机 Xcode 27.2 默认 SDK 在 Date 比较时缺少 Foundation 符号，独立最小示例也复现，未改项目超时逻辑。完整测试使用 native build system、已安装的 macOS 27.0 SDK 和 Xcode 的 SwiftUI 插件路径通过；不能将默认构建环境称为通过。
- 已有日历值未改动；新签名制品的实机验收尚未完成。
