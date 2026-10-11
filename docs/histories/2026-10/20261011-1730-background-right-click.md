# 后台右键与输入参数校验

## 诉求与实现

补齐 Safari 图片后台右键，并拒绝不支持的输入参数。未修改既有画中画工作，也未发布或更新宿主依赖 pin。

- `SkyClickSimulation` 接受右键单击，目标处发送 move/right-down/right-up；携带窗口字段和目标合成焦点，不移动真实鼠标、不 Raise。
- 右键仅走 SkyLight 通道。初版双通道在隔离 Chromium 中触发两次 contextmenu，已纠正；左键原有 primer 和双通道保持不变。
- auto 鼠标分支右键单击使用 SkyLight，AXShowMenu 仍优先；显式 app_post 保留为显式路径，不静默转换。
- click/pressKey/typeText 拒绝未知 options 字段及非法按钮/次数/方法。组合键通过完整 key 字符串传递；`modifiers`、`button`、`key`、`durationMs` 在不支持的 options 上报错，零 native 请求。
- 原生 click 不再把未知 mouse_button 降级为左键。

## 验证

- 定向 Swift 单元测试 27 项通过，包含非法 native 参数在窗口查找前拒绝、左键单/双击 recipe 不变、右键无 primer、unsupported count 和窗口归属。
- Today `just check` 通过（SwiftLint 1283 文件零违例、Markdown 检查通过、SwiftFormat 无待格式化文件）；检查命令临时优先使用 App 自带 Node，绕过机器上 Homebrew Node 缺失 llhttp dylib，不修改全局环境。
- fork 改动行已用 SwiftFormat 整理；默认 SwiftLint 全文件历史基线 193 项、当前 192 项，按文件/规则/严重性比较无新增违例（不宣称 fork 全仓 lint 干净）。
- fork JS 45 项、Today runtime 89 项通过；增加零请求断言和真实组合键透传断言。
- 隔离 Chrome 被 fixture 完全遮挡：左键单击一次、右键 contextmenu 一次、左键双击一次。校验前台应用、前台 first responder/key window、激活丢失次数、窗口层级和真实鼠标均保持。
- Today JS adapter + 本地新 fork native：Safari 图片元素 auto 和显式 sky_click 均打开菜单；Save Image As → 选中文件名 → Save 后，桌面 JPEG 读回成功（825×1000，194994 字节）。显式 sky_click 日志确认为 3 个事件、单 SkyLight 通道；各输入阶段采样的前台 PID/真实鼠标保持。
- Safari 后台 AX 菜单点击只选中 Save Image As；新观察确认选中后使用 sky_key Return 打开 sheet。脚本没有隐式重放或输入方法回退。
- 坐标实测另有一次失败：当前截图 733×1280，窗口 bounds 为 1325×860，截图裁切/比例与窗口映射不一致，点击未命中图片；日志确认右键已走 sky_click。该截图几何问题未在本次输入修复中更改，不能宣称任意坐标场景验收通过。

## 复跑

- `swift test --filter 'OpenComputerUseKitTests.testSkyClick|OpenComputerUseKitTests.testRightClick|CoordinateClick|ForegroundClick'`
- `OPEN_COMPUTER_USE_RUN_SKY_CLICK_LIVE_TEST=1 swift test --filter SkyClickLiveTests`（会启动隔离 Chrome profile 和 foreground fixture）
- `node --test scripts/node-repl/*.test.mjs`
- `node scripts/test-safari-right-click.mjs --save-test-image --title=expected-image-title --method=sky_click`（显式操作当前图片页、保存唯一命名测试 JPEG；可用 `--adapter` 选择宿主适配器）

这是 fork + adapter 局部工程验收，不是已发布 Today 主 App → lane → 模型自主验收。上游核心 SPI/AgentDisplay/Occlusion 文件保持原样；新增右键 recipe 是经过实测的 fork 扩展，不声称 Codex 内部实现相同。

## 原生参数校验复审补齐

复审发现 JS 适配器已拒绝 `modifiers`，原生 MCP/CLI 共用 dispatcher 却仍忽略它。本轮将校验放到 dispatcher 的 service 调用和预览状态变更之前。

- `NativeToolArguments.swift` 读取现有工具定义的属性白名单、基本类型、枚举和数值范围；兼容既有数字 element_index 与大小写方法名。hover 使用同一份定义，仅用于校验，不改变前台执行权限。
- 拒绝未知字段、显式 null、错误类型、布尔值冒充数字、非整数/非有限/溢出的整数参数，以及歧义或不完整的普通点击目标。非法可选值不再被当成省略而退回默认值。
- click_count 在 schema 中声明正整数，并使用精确整数转换；修复 Double(Int.max) 边界强转崩溃及布尔索引被桥接成 0/1 的问题。
- 错误仅列合法参数名和调用示例，不回显未知字段名、值或用户文本。
- 新增 9 项测试，覆盖真实 MCP JSON-RPC handler、CLI 批量首错停止、各工具未知字段、类型/数值边界、hover 合法观察、合法参数兼容。
- 实际编译后的 macOS CLI 和 MCP 子进程均验证 modifiers 明确报错；错误按钮类型及超大 click_count 被拒绝；合法 super+s 继续到既有快照检查。验证未绑定或操作任何用户 App。
- 完整 Swift 测试通过：主 XCTest 集 394 项、7 项需显式开启的实机测试跳过；Swift Testing 21 项通过。全量回归发现并修正上一轮漏更新的 CoordinateWindowTests 右键路由断言，并保留右键双击 app_post 覆盖。
- 新文件 SwiftLint strict 零违例，SwiftFormat 已执行；git diff --check、文档检查和核心 SPI parity 通过。仓库无 justfile；本轮未修改 Today 源码，无主 App 编译/发布/pin 更新。
