# 架构总览

这个仓库当前已经从模板收敛成一个本地 `computer-use` 项目。主线仍是 Swift 实现的 macOS automation MCP server，同时新增了实验性的 Windows 和 Linux runtime，用独立 Go 二进制暴露同一组 9 个 native Computer Use tools；Codex plugin 再在 native MCP 之上增加持久 Node.js REPL，向模型暴露 `js` / `js_reset`。

## 当前目录结构

- `apps/OpenComputerUse`
  主入口，负责 `mcp`、`doctor`、`list-apps`、`snapshot`、`call`、`turn-ended` 等 CLI 命令，以及 `-h` / `--help` / `-v` / `--version` 这类全局参数；不带参数启动时会先检查权限，只有缺失时才进入无 Dock 图标的 app 模式权限引导窗口，`doctor` 也只会在检测到缺失权限时拉起这套 onboarding UI。
- `apps/OpenComputerUseFixture`
  本地 GUI fixture app，用来承载低风险、可预测的点击/输入/滚动/拖拽验证路径。
- `apps/OpenComputerUseSmokeSuite`
  端到端 smoke runner，会拉起 fixture 和 MCP server，并通过 JSON-RPC 真实调用 9 个 tools；同时也支持单独的 visual cursor idle smoke，用跨进程 observation file 断言等待下一次 move 时是 anchored tip + tiny rotate wobble，而不是横向漂移。
- `apps/OpenComputerUseWindows`
  实验性 Windows runtime。它不依赖 Swift 或 `.app` bundle，Go CLI/MCP 入口会嵌入 PowerShell UI Automation bridge，构建产物是 `open-computer-use.exe`，并随已有 npm 包的 `dist/windows/<arch>/` bundled artifacts 分发。
- `apps/OpenComputerUseLinux`
  实验性 Linux runtime。它不依赖 Swift 或 `.app` bundle，Go CLI/MCP 入口会嵌入 Python AT-SPI bridge，构建产物是 `open-computer-use`，并随已有 npm 包的 `dist/linux/<arch>/` bundled artifacts 分发。
- `packages/OpenComputerUseKit`
  核心库，包含：
  - MCP stdio transport 与 tool registry
  - app discovery
  - Accessibility / 窗口 snapshot
  - 键鼠输入模拟
  - software cursor overlay
  - fixture test bridge
- `experiments/CursorMotion`
  独立的 Swift cursor motion lab，用于试验 `Bezier + arc + spring` 参数模型、调参 UI 和独立渲染，不直接耦合主 MCP runtime。
- `experiments/StandaloneCursor`
  新的独立 Swift cursor viewer，直接复用 `scripts/cursor-motion-re/official_cursor_motion.py` 里收敛出来的候选路径、score 与 raw spring timeline，用来观察更贴近 binary lift 的表现。
- `scripts/`
  仓库级自动化命令，包括 smoke test、`.app` 打包入口、Windows `.exe` / Linux binary 构建入口、npm 分发脚本、GitHub Release direct-download archive 打包、`scripts/node-repl/` 的 JS REPL adapter 与 npm CLI controller，以及 `scripts/computer-use-cli/` 这个用于探测官方 bundled `computer-use` 的 Go helper。
- `skills/`
  面向 agent runtime 的可安装 skill。当前 `skills/open-computer-use/SKILL.md` 只作为轻量入口和目录，安装、MCP/CLI 使用、排障等细节拆到相邻 `references/` 文件里按需加载；`scripts/package-skill.sh` 负责校验并打包 `.zip` / `.skill` 制品。
- `docs/`
  逆向分析、执行计划、history 和项目约束。

## 运行分层

### 1. App Mode 层

- `OpenComputerUse` 默认 app 模式会拉起 `PermissionOnboardingApp`。
- app bundle 以 `LSUIElement` agent-style 形态运行，默认不在 Dock 暴露常驻图标，但仍可按需显示权限窗口。
- 当用户从终端执行 macOS 版 `open-computer-use mcp`、`doctor`、`call`、`snapshot` 或 `list-apps` 时，CLI 会先通过 LaunchServices 启动同一个 `.app` bundle 的隐藏 app agent，并通过用户临时目录下的 Unix domain socket 转发请求；真正调用 Accessibility、ScreenCaptureKit 和动作 tools 的进程始终是 `Open Computer Use.app`，不是 iTerm / Terminal / Node launcher。默认 Socket 文件名保持历史兼容；嵌入式宿主可设置 `OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE`，使其使用 namespace 摘要对应的私有 Socket，避免与其他 OCU bundle 共用 Agent。
- CLI 与 MCP proxy 会把调用进程中 `OPEN_COMPUTER_USE_*` 前缀的环境变量随请求转发给 app agent，并只在该请求执行期间临时覆盖 agent 环境；这让 `click_method=global` 的进程级安全门和 debug 开关在 app-agent 架构下仍按调用方配置生效。
- 主窗口负责渲染 `Accessibility` / `Screen & System Audio Recording` 两类权限卡片、`Allow` / `Done` 状态和 relaunch 后的状态收敛；当两项权限都已完成时会自动关闭，不再要求用户手动退出。
- 辅助 drag panel 会跳转到对应的 `System Settings` 页面；点击 `Allow` 后，panel 会从主窗口里的按钮位置做一段 spring + curved frame 的入场，再落到 `System Settings` 内容区下沿。panel 默认保持在窗口右侧内容区下方居中并固定贴近窗口底边，不再依赖实时扫描权限页内部 `+ / -` 控件行；窗口层级上会显式排在当前 `System Settings` 窗口之上，避免被权限列表内容盖住，同时尽量减少对系统设置自身滚动区域的干扰。panel 内也补了显式返回按钮，允许用户中断当前 guidance、回到 onboarding 主窗口重新选择权限步骤。
- 权限状态会合并 TCC 持久授权记录与当前 app 进程的 runtime preflight：TCC 中任一匹配 client 已授权即可视为 granted，避免 CLI 子进程与 GUI app 对授权状态看到不一致的结果；如果当前 `.app` 进程已经通过 `AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()`，也会立即视为 granted，避免 stale 或不匹配的 TCC path 记录让 onboarding 浮层继续停留。正式 release 仍以 CI 打出来的 `Open Computer Use.app` 为准，而本地 debug/dev 打包现在显式命名为 `Open Computer Use (Dev).app`，并在 dev bundle 运行时优先认当前 dev 副本，避免系统设置里出现两个完全同名的条目。

### 2. MCP 层

- 面向 MCP host 的外部 transport 仍是 `stdio`；macOS 终端 CLI 到 `.app` app agent 之间额外有一层本地 Unix domain socket 代理，用来保证真实 automation 运行在 app bundle 权限身份下。
- 当 `OPEN_COMPUTER_USE_VISUAL_CURSOR` 未被显式关闭时，`mcp` 命令会切到一个最小 AppKit runtime：主线程保留 event loop 承载 overlay UI，stdio server 仍在后台线程串行读取与响应。
- 请求 framing 采用一行一个 JSON-RPC message。
- 当前支持的 method：
  - `initialize`
  - `notifications/initialized`
  - `notifications/turn-ended`
  - `ping`
  - `tools/list`
  - `tools/call`
- `notifications/turn-ended` 是开源版显式的 turn boundary hook；收到后会清理当前进程里的 visual cursor overlay、occlusion keep-alive 和 agent display。CLI `open-computer-use turn-ended [payload]` 也会通过 macOS distributed notification 通知正在运行的 AppKit MCP / app-agent 进程执行同一类清理，用于接 Codex legacy notify 的 after-agent payload。stdio server 退出和 app-agent client connection 关闭也会执行该 session cleanup。

### 宿主可选本地画中画

虚拟光标的目标尖端与实际输入目标保持相同位置，不为让整幅光标或光晕留在屏幕内而挪动目标；靠近屏幕/预览边缘时允许裁剪图形。移动、点击脉冲和 idle 使用同一目标，画中画复用其动画位置；动画在途帧仍可能尚未到达目标，不把单帧光标位置当作输入成功证据。

嵌入式宿主可用 `OPEN_COMPUTER_USE_LIVE_PREVIEW=1` 启用本地 ScreenCaptureKit 单窗口画中画。其目标来自 OCU 实际快照，连续帧不会加入 MCP 响应或模型上下文；输入期间预览穿透鼠标，收起、切窗和会话结束独立清理。`OPEN_COMPUTER_USE_PREVIEW_SESSION` 将恢复/停止通知限定到对应宿主 run。`OPEN_COMPUTER_USE_VISUAL_CURSOR_THEME=today` 可独立启用 Today 蓝色光标和淡光晕，默认保留上游样式。详见[本地预览记录](histories/2026-10/20261010-2155-local-window-preview.md)。

键盘工具（`type_text` / `press_key` / `paste_text`）开始时撤掉上一次虚拟光标，在本地预览顶部显示静态“键盘输入中”提示；连续调用合并提示，结束后 650ms 收起，下一次鼠标输入立即收起。后台合成焦点期间只暂缓本地帧合成：每轮首次暂停建立不可续期的 300ms 单调时钟截止时间，焦点释放后的 150ms 稳定等待也受该截止约束；到期展示最新帧，后续事件才能开启新一轮，不延长实际焦点生命周期，不增加输入重放或改变模型截图。长文本超出上限后继续预览。SCK `started` / 完整帧解码暂不可用保留上一帧最多 250ms；完整帧取消等待，blank / suspended / stopped / 未知状态立即清除，切窗、关闭或会话结束撤销旧回调。提示支持 AX 状态，窄窗口让开收起按钮，极窄窗口仅显示键盘图标。

采集会话显式持有 `SCStream`、帧事件流和 output/delegate 接收器，覆盖异步启动、帧消费及停止；不能假定系统流强持有回调对象。加载与不可用提示在预览内水平、垂直居中。

预览根据采集帧比例和当前屏幕 `visibleFrame` 同时约束宽高；切换目标保留长边尺度，尺寸变化、拖拽结束或屏幕变化后校正位置。边缘/四角使用本地缩放命中区和方向光标，内部拖动仅移动预览；输入期间仍穿透鼠标。非激活窗口使用 activeAlways 的 enter/move/exit 事件；悬停期间临时启用本进程 SkyLight `SetsCursorInBackground`，离开、收起或输入穿透前恢复原值，动态符号缺失时记录错误且不激活应用。预览保留黑色底衬，图像填满受比例约束的内容区以避免像素舍入留边，不裁切源窗口，也不改变模型截图。详见[预览 UI 修复记录](histories/2026-10/20261011-1642-preview-ui-layout.md)。

### 3. Tool Service 层

主窗口截图只采用完整窗口覆盖：窗口完全位于单个 CG 显示器内时可优先硬件捕获并检查比例；部分出屏、跨屏或比例异常时使用 ScreenCaptureKit 独立窗口捕获。SCK 的窗口 frame、过滤器内容尺寸必须与已绑定窗口一致，输出尺寸使用该过滤器自身缩放。无法确认完整覆盖时只保留可用 AX 状态，不返回部分图。主窗口坐标输入（含单次前台点击、坐标 hover 和 drag）在投递前检查截图尺寸、比例和像素边界；不把截图缺失视为 1:1，也不自动重试输入。弹层仍使用独立 captureBounds/token 契约。

普通窗口观察会附加同进程、几何关联的可见弹层图片，每幅图片紧邻自己的说明。主窗口图像及其坐标保持原样，附图不能用于主窗口坐标点击。同 PID、前后顺序和几何关系只产生候选，不构成父子所有权证明；独立标准 AX 窗口被排除。

弹层图片单独携带 `captureBounds`，表示实际图像覆盖的屏幕区域；窗口 `bounds` 只继续承担身份、几何和接收者校验。点击按编码后像素尺寸映射到 `captureBounds`，不把被裁剪的图片拉伸到整个窗口。单窗口 SCK 采集明确采集完整窗口且不留边；缺少区域元数据的硬件图片仅用于观察，不生成可点击 token。不从图片长宽比猜测裁剪方向，不硬编码屏幕边缘偏移，多显示器负坐标保持原值。

显式只读弹层观察在主快照失效后可以重建状态，但保留首次绑定进程的 PID 与启动时间，不能按同名重新选择应用。恢复前后均复核身份，清除旧弹层凭证与单次前台资格；只有完整新快照成功后才发布新索引。进程退出或身份改变要求显式重新绑定。输入失败或未知结果仍不能重放。

主窗口观察附加本轮活动系统菜单的 AX 子树，保留主窗口身份。只有选中项、菜单焦点链、明确展开或可见证据才发现候选；可选属性缺失时，使用同进程独立可见窗口的唯一几何匹配，并在结束前复核。菜单项不默认展开其隐藏子菜单；窗口内部普通菜单保留既有遍历。无候选 discovery 预算为 12ms，有候选后 discovery 与复核总预算为 60ms，单次 AX IPC 至多 4ms；后续语义渲染仍受既有节点数/深度约束。这些预算不等于操作系统同步调用的硬中断，也不包含普通 AX renderer 的全部耗时。

弹层的后台输入要求显式 `popup_token` 和 `sky_click`，只允许图片局部坐标的左键单击。一次性凭证绑定主窗口与弹层身份、几何和有效期；锁等待、焦点准备及每次 mouse-down 前复核。global 要求桌面精确鼠标接收窗口匹配；sky_click 定向到凭证绑定窗口，并复用普通后台点击的同应用上层窗口/Space 遮挡校验，不用其他 App 的前台命中否决定向输入。失败不换路、不重放，已投递事件的结果须重新观察。普通后台点击的单通道投递与短时菜单焦点生命周期见下文；键盘、滚动及拖拽的输入投递路径不变。

弹层采集是有总预算的附加观察：先筛选 WindowServer 候选，再执行有界 AX 查询和截图。弹层截图（概览与实时预览共用）按显示器过滤、只包含弹层和它的主窗口并裁剪到弹层位置，底色用跟随系统外观的窗口背景色（半透明材质背后没有内容时会合成为深灰），再按硬件缓冲区里弹层自身的透明度做蒙版，圆角外与不可见的辅助窗口保持透明；不包含桌面层与其他应用。跨屏或部分离屏时退回硬件缓冲区（要求图片与完整窗口等比）。不使用独立窗口过滤器：系统会把 sheet / popover 与父窗口分组，整组缩放进弹层尺寸。超时或未完成时返回已有主窗口结果并明确标记观察不完整；迟到结果不进入输入缓存。主窗口预览独立验证窗口存在性，切换 Space 不因屏上候选缺失而停流；弹层失效只撤销附加图层。

- `ComputerUseService` 负责把 Computer Use tool 请求映射到本地能力，`ComputerUseToolDispatcher` 则把工具的参数解析与 service 方法分发收敛成 MCP server 和 `open-computer-use call` 共用的一层。macOS dispatcher 在清理 popup、更新输入预览或调用 service 前，按工具定义校验字段白名单、必填项、基本类型、枚举和整数边界；未知字段不再静默丢弃，错误不回显任意输入内容。保留数字元素索引及方法名大小写兼容。独立的 JS 选项校验不能替代此入口校验。
- Codex plugin 的 `.mcp.json` 默认不把 native tools 直接暴露给模型，而是启动 `scripts/node-repl/open-computer-use-repl.mjs`。adapter 以 child MCP client 连接同一个 native runtime，并只对外列出 `js` / `js_reset`；JavaScript 通过异步 app-bound API（`cua.getApp(...)`、`app.click(...)`、`app.getAXState()` 等）调用 native tools。
- REPL 使用 Node.js 自带的 evaluator，因此保留 top-level `await` 和跨调用 lexical bindings；真正执行代码的 kernel 位于 Worker 中，超时会终止 Worker 并重建干净 session，避免 `while (true)` 挂死 MCP transport。
- npm launcher 还直接提供 `ocu js` 和 `ocu repl`：前者为一次性 Worker/native MCP session，后者在当前终端内保留同一个 session 和 binding；两者退出后都会关闭 Worker 与 native MCP child。`ocu capabilities [--json]` 在不启动 native MCP 的情况下报告 Node、adapter、kernel 和当前平台 native artifact 是否齐全。help 始终显示 code-first 命令并标记 availability，不按环境动态隐藏接口。
- npm bin 当前本身通过 `#!/usr/bin/env node` 启动，因此完全没有 Node 的 shell 无法进入 help/capability 检测；launcher 启动后会复用 `process.execPath`，不会再次从 PATH 解析 Node。若未来要求零 Node 前置，应把最外层入口替换成 native bootstrap 或随包分发 Node。
- 这是增量迁移：`open-computer-use mcp` 保留原生 9-tool compatibility surface，macOS 的应用绑定与普通观察通过 `get_app_state.initialize` 区分，不增加生命周期工具；hover 开启后为 10 个。
- `list_apps` 通过 Spotlight metadata query 拉取标准 application 目录里的 app bundle，并读取 `kMDItemUseCount` / `kMDItemLastUsedDate_Ranking` 这类系统元数据；再与 `NSWorkspace` 的运行态 app 合并，输出“当前运行中 + 近 14 天用过”的视图。
- `get_app_state` 优先走真实 AX / 窗口截图；真实 app 必须同时有未最小化的 `AXWindow` 和可匹配的 on-screen `CGWindow`。普通观察不激活或抬升窗口；绑定时可后台启动或 reopen 一次，launch/reopen 回调返回后仅首次绑定使用单调时钟最多 3 秒的窗口就绪等待（约 100ms 间隔，出现即返回）；只探测 AX/CG 元数据，AX 单次读取最多 50ms 且受剩余预算约束，不截图、不遍历完整树、不激活或重放打开。等待前后验证 PID/启动时间身份，取消与权限错误立即退出。3 秒仅是窗口等待预算，不含系统启动调用和就绪后的完整快照；同步系统调用不承诺硬实时截止。首轮等待超时后，200ms 内只读确认 AX 窗口集合为空，且 CG 同进程记录全部未显示、无任何 Space 归属，才在后台（不激活）对同一进程补发一次 reopen 并再等一轮。WindowServer 保留的辅助记录不能直接证明存在业务窗口；可见、其他 Space、归属未知、AX 不可读或迟到结果仍禁止 reopen：实测 Numbers 在无窗口状态下被强制结束后，后台冷启动会恢复成无窗口状态、不弹打开面板，收到 reopen 才显示。两轮都超时才保留 pending initialization 并报告应用已启动、窗口未就绪，后续只读观察可恢复。普通观察与就绪后快照竞争仍沿用原有短重试，仍无法匹配则返回 `Apple event error -10005: cgWindowNotFound`，不把 application 根节点或无截图窗口伪装成可操作状态。当目标是仓库内 fixture app 时，回退到 fixture 导出的合成状态。真实 AX tree 默认在 macOS、Linux、Windows 上最多渲染 1200 个节点、64 层深度；显式 `get_app_state` / `snapshot` 可通过 `max_tree_nodes` / `max_tree_depth` 覆盖预算，action tools 的刷新结果仍使用默认预算。snapshot 文本默认截断到 500 字符；显式 `get_app_state` / `snapshot` 可通过 `text_limit` 正整数或 `"max"` 覆盖，action tools 的刷新结果仍使用 500 字符默认值。对 Electron/WebView 这类深层 UI 会压缩空 `AXGroup` / `AXUnknown` wrapper、过滤 `AXScrollToVisible` 噪音和空字符串属性，避免 action-critical 的输入框被无语义容器挤出节点预算；但通用节点中的 `AXPress` / `AXConfirm` / `AXOpen` 子节点会形成文本摘要边界，避免多个可点击选项被合并成一个 container。这类动作节点如果 frame 有效、尺寸紧凑且不包含带 URL 的 `AXLink` 后代，会保留为带窗口相对 `Frame` 的 `button`，并用短文本后代作为按钮摘要，让 icon-only 和文字 Web 控件都能获得可区分的 `element_index`；包含带 URL 的 `AXLink` 后代时保留通用 wrapper 和链接子节点，避免导航链接被摘要吞掉。对原生 open panel / Finder column view 这类把内容放在 `AXContents` / `AXVisibleChildren` 里的控件，也会把可见文件项纳入元素树。
- MCP 基础 9 个工具的 description / input schema 按官方 `computer-use` 文案和参数面收敛；macOS 额外提供只读的 `query`；应用初始化是 `get_app_state` 的参数，不另增 `open_app` 工具。
- JS REPL 的 API 和当前官方 code-first 形态对齐到异步 app binding，而不是把离散 tools 简单包成同步函数。snapshot 的 `windowPlacement` 以及 keyboard action 的 `keyMethod` 会转换成 native tool 的 snake_case 参数。实现不复制或运行 proprietary `@oai/*` package；协议和行为记录在 `docs/references/js-repl.md`。
- `open-computer-use call <tool> --args '{...}'` 会直接输出 MCP-style JSON result；`open-computer-use call --calls '[...]'` / `--calls-file <path>` 会在同一进程里顺序执行 JSON 数组里的 tool calls，并复用同一个 `ComputerUseService` 内存态，因此 `get_app_state` 之后的 action tool 可以继续使用同一轮 snapshot 的 `element_index`。序列执行默认会在成功的相邻操作之间 sleep 1 秒，也可以用 `--sleep <seconds>` 覆盖；遇到 `isError=true` 的 tool result 后停止。
- 对真实 app 的 `get_app_state` / action tool 入口，当前只保留一层密码管理器 bundle denylist：bundle-id 直传时直接返回 safety denial；名称匹配时默认不解析到这些 app。终端、Chrome / Atlas 和系统组件不再属于内置阻止目标。
- 普通 app 的 element frame 当前按“窗口左上角为原点”的 window-relative 坐标输出，便于后续把 `element_index` 和截图坐标统一到同一套参考系。
- macOS 显式 `get_app_state` 支持 `include_ax` / `include_screenshot`（移植自上游 #101，Windows / Linux 未移植），默认 true，至少保留一项。JS 对应 `includeAX` / `includeScreenshot`，CLI snapshot 提供同名连字符参数。关闭 AX 跳过树、焦点和选区，并使该进程旧快照编号与查询编号失效；关闭截图跳过捕获与编码，坐标点击和拖拽会在发送输入前拒绝，需重新获取截图。见 [按需观察](selective-observation.md)。
- `click` / `set_value` 在执行真实动作前后，会额外驱动一层透明 `SoftwareCursorOverlay` window：两者的移动阶段现在共用一条 heading-driven 的官方风格 motion 内核，显式把“当前 cursor 朝向”和“最终 resting pose”一起喂给选路器，优先生成需要时先掉头、再沿车头方向推进的 C 形/单侧大弧轨迹；首次显示时按官方 binary 的 fresh state 从 AppKit 全局 `(0,0)` window origin 生成起点，后续动作继续复用上一帧 visible tip。真正显示出来的 cursor 不再直接等于 path sample，而是经过一层独立的 visual dynamics 状态，把 visible tip、velocity、angle 和 fog/offset 持续推进。`click` 结尾会衔接 click pulse 和更明显但仍然很小的 rotate wobble，`set_value` 则只做 settle / idle，不给 pulse；两者收尾后会在目标点继续保持 idle 状态，等待下一次动作时 tip 保持 anchored、只保留可感知的小角度摆动；只有连续 30 秒没有新动作时才做 cleanup，这样连续 tool call 不会反复从 fresh `(0,0)` 起步；如果宿主在任务 / turn 结束时发出 `turn-ended`，cursor 会立即消失并清掉本轮位置状态。
- overlay 的 visual style 不再自己从官方 app bundle 裁 `SoftwareCursor` 小图；主 MCP runtime 现在和 `CursorMotion` 一样优先渲染仓库里沉淀的 `official-software-cursor-window-252.png` baseline，只有资源缺失时才退回 `OpenComputerUseKit` 内部的程序化 pointer/fog fallback。命中点 anchor 仍固定在 `126x126` 画布里的同一组 tip-offset 上；glyph 自身的 neutral heading 继续沿用 `CursorMotion` / 官方 baseline 的 `-3π/4`。主 runtime overlay window 按 AppKit 全局坐标移动，因此在把 AX / `CGWindowList` 产出的 y-down screen-space 点击目标喂给 overlay 之前，会先转换成对应屏幕的 AppKit 全局坐标；路径选路用屏幕上实际可见的 AppKit forward heading，进入 visual dynamics / render state 前则把 velocity 的 y 轴翻回 CursorMotion 的 y-down screen state，再交给 AppKit 绘制层做角度和 `dy` 翻转。程序化 fallback 保留 neutral artwork correction，把它的天然轮廓轴对齐到 `CursorMotion` / 官方 baseline 的 `-3π/4` forward 方向，但不让实验线依赖 runtime 代码。
- overlay 的层级不再固定 `.floating`；现在会跟随 snapshot 命中的目标 window id / layer，把自己排到该目标 window 之上，而不是粗暴压到所有前台 app 最上层。
- overlay 的曲线路径不再只按固定 Bezier 模板生成；当前主线采用 reverse-engineering 约束下的 heading-driven candidate 族，候选只保留 `direct` / `turn` / `brake` / `orbit` 这些能稳定产出单侧主弧的 family，并继续保留 target-window 命中策略作为同类候选间的 tie-break。原始 binary lift 恢复出来的 `20` 条路径和 score 仍然保留在独立的 `StandaloneCursor` viewer / Python 重建脚本里，用于对照分析，不再直接作为 runtime 默认 chooser。
- overlay 的 progress 曲线也不再是固定 `easeInOut`；主线现在复用官方 `response=1.4`、`dampingFraction=0.9`、`dt=1/240` 的 spring/`VelocityVerlet` 形状，默认 move 时长对齐已恢复出的 close-enough endpoint-lock 时间 `343 / 240 = 1.4291667s`，不再按路径距离额外压缩。
- overlay 不再依赖临时 `terminal settle` 补丁来修尾；主线现在统一改成“路径层给目标点，visual dynamics 层给可见姿态”的双层模型，所以 move 末段、pulse 和 idle 共用同一套状态，不会再出现 endpoint 锁住后只剩原地翻角的收尾。
- overlay 的渲染输入也从单一 `rotation` 扩展成 `rotation + cursorBodyOffset + fogOffset + fogScale`，让速度滞后能真正体现在画面上，而不是只存在于主循环内部状态；其中 `rotation` 现在按二进制里 `SoftwareCursorStyle.angle + CursorView._animatedAngleOffsetDegrees` 的分层去近似，不再把“跟随运动方向的主朝向”和“小幅 wiggle offset”压成同一个受限小角度。
- 动作型 tools 对普通 app 采用“非侵入优先，物理指针路径显式 opt-in”策略：
  - `perform_secondary_action` 只执行目标元素已经暴露出来的 AX action；Safari 这类 AppKit custom action descriptor（例如 `Name:close tab ...`）会显示为短名称并准确映射回过滤后的原始 AX action，避免 raw/rendered action 错配；短名称与其他显示名称或任一其他原始 AX action（包括被过滤的动作，忽略大小写）冲突时保留完整 descriptor，保证输出 selector 不被原始动作精确匹配抢占；无效或歧义 action 返回官方风格的 `... is not a valid secondary action for ...`，fixture 的 `Raise` 路径也不再为了测试去准备全局物理指针输入
  - `set_value` 会先用 `AXUIElementIsAttributeSettable(kAXValueAttribute)` 判断目标是否真的是可设置值元素，只有 settable 时才调用 `AXUIElementSetAttributeValue`；不可设置时返回官方风格的 non-settable 错误，不退到键盘输入、剪贴板或未公开的文本替换接口
  - `click.click_method` 是开源版的可选扩展，支持 `auto`（默认）、`accessibility`、`app_post`、`sky_click` 和 `global`。坐标 auto 的 fork 路由见下文；元素索引的 AX 选择不变，鼠标兜底与坐标共用自动路由；显式模式不会静默 fallback 到其他实现。`accessibility` 只接受 `element_index`；其余 mouse 路径可以使用 `element_index` 的计算落点或原始 `x/y` 坐标。
  - element-targeted `click` 的 `auto` 左键路径会先试原生列表的 `AXSelectedChildren` 选择；选择一旦发送，任何 AX 失败都直接抛出，不能继续激活或鼠标回退。带 AXOpen 的列表文件项若实时选择能力缺失，在发送前拒绝，避免单击被解释成打开。普通不可选择的内层列表仍可向外查找可选择外层列表，未知或权限错误仍停止。没有选择输入的其他目标再试 `AXPress` / `AXConfirm` / `AXOpen` 这类真正语义化的激活动作；如果目标本身不可点，还会继续尝试其子孙 AX 元素（例如 Finder sidebar row 下面暴露 `AXOpen` 的 cell）和命中点附近的 AX hit-test 结果，最后进入现有 non-AX 分支：默认左键单击/双击和右键单击使用 `sky_click`，其他按键使用经独立窗口校验的 `app_post`；只有明确的自动前台策略才使用全局 HID 事件。`AXRaise` / `kAXMainAttribute` / `kAXFocusedAttribute` 这类 activation-only fallback 只在显式 accessibility 模式允许窗口级元素使用，auto 不走此分支，避免普通静态文本或容器把“获得焦点”误报成“点击已处理”；`click_count > 1` 也会优先重复可用的 AX action。
  - 显式 `click_method=accessibility` 只执行上述 AX 语义动作；显式 `click_method=app_post` 绕过 AX 候选和后代扫描，直接通过 `CGEvent.postToPid` 向目标进程发送 `mouseMoved` / down / up；显式 `click_method=sky_click` 在 macOS 接受左键单击/双击和右键单击，验证当前 snapshot 的 `CGWindowID` 仍为同一 PID 所有。鼠标事件每个只经 `SLEventPostToPid` 投递一次；左键单击与右键单击仅包含目标处 move/down/up，左键双击保留原有 primer 与 click-state 序列。后台目标通过 `SLPSPostEventRecordTo` 获取短暂 synthetic-active 状态，普通左键还准备目标 key window；后台普通左键单击在 key record 后等待 100ms 供目标处理焦点，再发送鼠标事件。这段等待不按 skyClickDelayScale 缩短，不用于双击、右键、前台点击或已有弹层续点；它不是投递成功的证明，仍须读取结果。不向真实前台应用发送 defocus record，也不移动真实指针。目标本来在前台时不创建或撤销合成焦点。

    `ComputerUseToolDispatcher` 以会话持有 `SkyClickMenuFocus`：左键单击后最多轮询 120ms 检查新增的同 PID、几何相关窗口。检测到候选后，合成焦点最多保留 30 秒，供后续只读观察和一次性 popup-token 点击使用；候选不构成输入授权，原窗口/几何/接收者校验不变。普通无 lease 的状态读取不增加等待。菜单消失、根窗口改变、应用切换、调用失败、会话结束或超时会清理；用户将目标带到前台及 PID 复用时不发送旧 deactivate。后续 popup 点击可复用焦点，不重新将主窗口设为 key。单进程内的 owner 与 generation 防止旧会话的 timer 关闭新交互；其他连续动作与清理互斥，动作回读后复核弹层：原弹层仍在或出现本动作的新关联弹层时保留/交接焦点，不延长原 30 秒期限；菜单消失、身份/根窗口改变、前台接管或失败时结束。无 lease 的普通动作不新增等待，底层键盘自己的焦点逻辑保持原样。`list_apps` 不进入菜单生命周期，成功或失败均不切换菜单焦点，但仍消费旧弹层输入凭证与一次性前台观察资格，避免越过相邻观察约束。独立 `ComputerUseService` 的直接调用没有跨请求 lease。

    `sky_click` 的 action-result snapshot 刷新仍禁止 activate / `AXRaise` 恢复，目标状态瞬时不可读时直接失败，任一步失败不 fallback、不重放。局部 Today Helper 实验证明后台颜色箭头可打开色板并进入 Colors；File 增加 key 准备等待后，也能后台打开并通过 popup-token 点击进入 Export PDF File，随后取消。不能据此宣称所有菜单都支持后台执行。显式 `click_method=global` 同样绕过 AX，但通过 `.cghidEventTap` 发送系统级指针事件。`global` 还必须设置 `OPEN_COMPUTER_USE_ALLOW_FOREGROUND_CLICKS=1`、点击前台策略或全局指针授权，否则在移动 visual cursor 或发送输入前拒绝请求。
  - `get_app_state` 解析目标窗口时先看 on-screen 窗口，再退到所有窗口，所以位于其他 Space 的窗口不会触发 activate / raise 恢复；拍到未被遮挡的窗口后会关闭它的 WindowServer occlusion 通知（`WindowOcclusionKeepAlive`），之后被遮挡或切换 Space 时 Chromium / Electron / WebKit 仍保留页面与 `AXWebArea`。keep-alive 保存 SPI 返回的原始开关状态，并在 turn-ended、MCP/app-agent connection 关闭、server 正常关闭或进程退出时恢复；恢复失败的记录保留到后续重试。因为 snapshot 会维护该状态，macOS `get_app_state` 不声明 `readOnlyHint`。Chromium 系 app 的 web AX tree 是懒加载的，窗口可见时最多重走 3 秒，被遮挡时在 tree 末尾追加说明。`sky_click` 不再要求窗口 on-screen。详见 `docs/references/macos-window-visibility-and-spaces.md`。
  - 窗口截图主路径是 WindowServer 的 `SLSHWCaptureWindowList`（任何 Space、被遮挡均可，15–45 ms），ScreenCaptureKit 为 fallback；AX root window 通过 `_AXUIElementGetWindow` 直接绑定 `CGWindowID`。输入 recipe 的固定间隔都是环境变量可调的校准旋钮，默认值来自基准测试（见 `docs/references/macos-window-visibility-and-spaces.md`）。
  - `get_app_state.window_placement` 是开源版的可选扩展：`keep`（默认）、`agent_display`、`restore`。`agent_display` 通过 `AgentDisplay` + `packages/OpenComputerUseVirtualDisplayShim` 创建 agent 专用 virtual display，用 AX 位置把目标窗口的 frame 移过去（不激活、不抬升），让已被遮挡或在其他 Space 的窗口对其 app 真正可见；`restore` 按 app PID 恢复当前 runtime 停放的全部窗口，session cleanup 或进程退出也会恢复全部窗口并销毁显示器。恢复失败时保留原位置记录和 virtual display，避免把未恢复窗口误记为成功并允许后续重试；已关闭的窗口则直接清除记录。shim 捕获私有 KVC/selector 的 Objective-C exception，并把不兼容系统收敛为创建失败。Windows / Linux 对非 `keep` 值返回 unsupported。
  - `type_text.key_method` / `press_key.key_method` 是开源版的可选扩展，支持 `auto`（默认）和 macOS-only 的 `sky_key`。本 fork 的两者在 macOS 共用后台键盘链路，已在前台时直接定向投递并验证接收窗口；后台时复用 `sky_click` 的 target-only synthetic-active record，再投递 yabai 的 make-key-window record 让目标 app 在进程内把当前 snapshot 窗口设为 key window，之后走现有 `CGEvent.postToPid` 键盘路径；带 `cmd` 的单字符组合键改为在目标 AX 菜单栏找到对应菜单项并 `AXPress`。它不要求窗口 on-screen（可用于其他 Space），但对隐藏 app fail closed；action-result snapshot 与 `sky_click` 一样使用 read-only recovery policy。
  - 对 renderer 合成的 summary `text` 行，`click` 不再默认点击父容器中心；这类元素使用左侧安全锚点。对普通 row/container/text 的后代候选，也会过滤右侧紧凑 hover action（例如 Lark / Electron 会话列表里的“完成”勾），避免把主行点击误操作成 side action；Electron/Lark 这类 app 的 WebArea 合成文本会优先寻找紧邻的行级 `AXPress` 祖先并静默执行，避免用物理鼠标点行。浏览器 WebArea（例如 Chrome/GitHub）不走这条 Electron-scoped 行级祖先点击优化，仍保留通用 link/container 点击路径。命中点如果只反查到覆盖整页的 Electron/WebArea 级 AX 元素，不再继续扫描整个大容器的子孙候选，避免一次行点击被远处的可点击元素截走。
  - `AXUIElementCopyElementAtPosition` 做坐标命中，尽量把 coordinate click 反解成可操作 AX 元素
  - `CGEvent.postToPid` 定向发送键盘事件，避免为了 `type_text` / `press_key` 抢前台；`type_text` 会把文本按 Unicode extended grapheme cluster 聚合成小批量 `keyboardSetUnicodeString` 事件，避免中文标点、emoji / 代理对和组合字符被逐个 UTF-16 code unit 拆开后在 Electron 富文本输入框里乱序或变形。默认 auto 输入前实时读取目标 App 的焦点并校验 PID、绑定窗口、可编辑角色和禁用状态；合成 key-window 状态建立后再次确认仍是同一输入框，不要求目标为系统前台。`type_text` 不再拼接旧 AXValue，保留插入点和选区的键盘语义；显式 `set_value` 保持不变。接收者不明时拒绝，投递后的错误不换路重放；焦点摘要在树裁剪时仍显示角色并明确无索引；`press_key` 的 xdotool parser 覆盖官方 binary key table 里常见的 `BackSpace`、`Page_Up`、`Prior` / `Next`、`F1...F12` 和 `KP_*` alias
  - `scroll.pages` 对齐官方 `1.0.755` 的 `number` schema，支持小数页数；整数页且目标暴露 `AXScroll*ByPage` 时优先走 AX action，否则用 `CGEvent.postToPid` 向目标进程定向发送 scroll event
  - `drag` 仍是 coordinate-only API，但默认不再使用全局 `.cghidEventTap` mouse event；默认改为 `CGEvent.postToPid` 定向发送 mouse move / down / dragged / up 事件，避免移动用户真实硬件光标；这些 coordinate tool 的 `x/y` 先按 screenshot pixel 坐标解释，再依据截图像素尺寸与目标 window bounds 的比例映射回 window point / Quartz global 坐标，避免 Retina 窗口上把 2x 像素误当成 1x point 导致点击落到错误位置
  - `click` / `scroll` / `drag` 在环境变量未开启的默认配置下不会走全局 `.cghidEventTap`，因此不会移动或抢占用户真实鼠标；`OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 是全局指针能力的进程级安全门，显式 `click_method=global` 仍必须通过这层授权。默认路径不再为了 fallback 调用 `NSRunningApplication.activate`。`drag` 的结果会在 snapshot 文本之后、截图之前附带一条 `Drag delivered via ...` 文本项，说明本次走的是 `app_post` 定向投递还是全局指针路径；默认路径下同时说明 `postToPid` 事件不经过 window server，因此无法驱动窗口移动、文本拖选、Finder 拖放这类 window server 拖拽会话。`drag` 的 tool description 也同步说明了这一限制和对应环境变量。显式开启全局路径后，拖拽使用默认 event source 向 HID tap 投递，按距离插值并为每步写入位移 delta；macOS 26+ 的 down / dragged / up 还会共享一个手势事件编号，使 window server 能识别窗口移动、文本拖选和 Finder 拖放所需的真实拖拽会话

### 4. Fixture Bridge

- `OpenComputerUseFixture` 会把自己的窗口与元素状态写到临时 JSON 文件。
- 对 fixture 的 `get_app_state` 和少量测试专用动作，会通过 `FixtureBridge` 走显式 command 通道。
- 这个 bridge 只服务于仓库内 deterministic smoke path，不是面向真实第三方 app 的能力边界。
- 因为 SwiftPM 裸 executable 形式启动的 fixture 没有稳定的 bundle identifier，`list_apps` 会仅对 `OpenComputerUseFixture` 注入一个内部 synthetic identifier，保证 smoke suite 仍能覆盖 `list_apps`，普通第三方 app 仍按真实 bundle id 输出。

### 5. Cursor Lab

- `StandaloneCursor` 是一个新的独立 SwiftUI/AppKit demo target，可通过 `swift run StandaloneCursor` 本地启动。
- 这条线优先验证 Python 重建脚本已经收敛出来的核心：`20` 条候选路径、`measure + score`、`prefer in-bounds then lowest-score` 选路，以及 `response=1.4` / `dampingFraction=0.9` / `dt=1/240` 的 raw spring timeline。
- 当前它刻意不引入 speculative 的 wall-clock duration 映射，也不复用 `CursorMotion` 里更偏视觉手感试验的 pose dynamics。
- `CursorMotion` 是一个单独的 SwiftUI demo target，可通过 `swift run CursorMotion` 本地启动。
- 这条线优先验证 motion model 本身：当前主线是 heading-driven 的 turn / brake / orbit / direct candidate 族、spring progress、独立 visual dynamics 和 debug UI；moving 阶段真正画出来的箭头角度会持续跟随 visual dynamics 的主 heading，接近停住后再平滑回到默认 resting pose，并在 idle 阶段保留原地小摆角。
- lab 的 cursor 视觉继续以 `scripts/render-synthesized-software-cursor.swift` 为参考：优先使用仓库里保存的官方 `252x252` runtime baseline 图，缺失时再退回脚本里的 procedural pointer/fog 近似；settle 态也改成中心固定的小幅摆角，而不是继续沿 XY 轻微漂移。
- 当前它不接真实 tool call，也不回写主 `SoftwareCursorOverlay`，目的是把实验噪音与产品行为边界隔离开。

### 6. Windows Runtime

- Windows runtime 位于 `apps/OpenComputerUseWindows`，以 Go 维护 CLI、`call --calls` sequence、MCP JSON-RPC、tool schema 和进程内 snapshot cache。
- 构建入口是 `scripts/build-open-computer-use-windows.sh --arch arm64|amd64`，默认输出到 `dist/windows/<arch>/open-computer-use.exe`；npm release package 会把两个 Windows artifact 内置到已有 root/alias packages，Node launcher 按 `process.platform/process.arch` 自动选择。
- Go runtime 通过 `go:embed` 带上 `runtime.ps1`，执行 tool call 时临时落盘并调用 Windows PowerShell。PowerShell bridge 使用 `System.Windows.Automation` 做 app/window/element discovery、tree rendering、UIA pattern action、ValuePattern set value 和 ScrollPattern scroll；当目标 app 不暴露对应 pattern 时，fallback 到 `PostMessage` / `SendMessage` 形式的 Win32 window message。
- Windows runtime 默认只连接已经运行的 app，不会在 `get_app_state` 找不到进程时自动 `Start-Process`，也不会默认允许 `SetFocus` secondary action；这两条前台抢占路径分别需要 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH=1` 和 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1` 显式打开。`type_text` 默认优先对可写文本控件的 child HWND 发送 `EM_SETSEL` / `EM_REPLACESEL`，不再默认走可能触发前台激活的 UIA `ValuePattern.SetValue` fallback；需要旧行为时必须设置 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1`。UIA pattern 和 Win32 message fallback 本身仍是 best-effort：很多控件可以在后台响应，但 Windows 没有一套对所有 GUI toolkit 都等价于 macOS AX 的后台键鼠输入模型。
- Windows screenshot 会先检查主窗口可见、未最小化、未被 DWM cloaked、与 virtual screen 相交，并要求窗口宽高至少 64 像素且面积至少 20,000 像素；`list_apps` 也只列出通过这组可捕获性检查的窗口。PowerShell bridge 通过后，Go 层还会解码 PNG header 并用同一尺寸门槛复核。任一检查失败时 snapshot 仍可返回 UI Automation tree，但省略 MCP `image` block；coordinate click / drag 会明确失败，element-targeted action 仍可尝试。实现不会为退化窗口放大、补边或生成占位截图。
- 这 9 个 tool 的协议面与 macOS 主线保持一致：`list_apps`、`get_app_state`、`click`、`perform_secondary_action`、`scroll`、`drag`、`type_text`、`press_key`、`set_value`。其中 element-targeted action 会优先复用上一轮 `get_app_state` 的 runtime id / automation metadata，coordinate action 使用 screenshot/window-relative 坐标。
- Windows `click_method=accessibility` 映射到 UI Automation pattern，`app_post` 映射到 HWND `PostMessage`；macOS-only 的 `sky_click` 和没有实现的 `global` 都会在 snapshot lookup 前明确返回 unsupported。`type_text` / `press_key` 的 `key_method=sky_key` 同样在 snapshot lookup 前返回 unsupported。`auto` 仍保持 UIA 优先、window message fallback 的现有行为。
- Windows UI Automation 需要运行在已登录用户的桌面 session 里。通过 SSH 作为脱离桌面的后台进程运行时，PowerShell 可以启动并返回 JSON，但系统可能不给它暴露顶层窗口；这种情况下 `list_apps` 会是空，`get_app_state` 可能返回 `appNotFound(...)`。
- Windows 已有独立 WPF 观察 fixture 和 Windows PR smoke，覆盖观察通道及截图边界。其余工具 / toolkit 覆盖，以及 visual cursor overlay、installer/onboarding、code signing 仍待补齐。后续 TODO 记录在 `docs/exec-plans/active/20260422-windows-computer-use-runtime.md`。

### 7. Linux Runtime

- Linux runtime 位于 `apps/OpenComputerUseLinux`，以 Go 维护 CLI、`call --calls` sequence、MCP JSON-RPC、tool schema 和进程内 snapshot cache。
- 构建入口是 `scripts/build-open-computer-use-linux.sh --arch arm64|amd64`，默认输出到 `dist/linux/<arch>/open-computer-use`；npm release package 会把两个 Linux artifact 内置到已有 root/alias packages，Node launcher 按 `process.platform/process.arch` 自动选择。
- Go runtime 通过 `go:embed` 带上 `runtime.py`，执行 tool call 时临时落盘并调用 `python3`。Python bridge 使用 GNOME/GObject Introspection 暴露的 AT-SPI2 接口做 app/window discovery、accessibility tree rendering、semantic action、editable text、value set，以及 best-effort 的 key/mouse fallback；文本能力通过 `Accessible.get_interfaces()` 检测 `Text` / `EditableText`，不依赖不同 PyGObject 版本未必存在的便捷属性。
- Linux 上最接近 macOS AX 的是 AT-SPI2/D-Bus accessibility，而不是一套统一的后台键鼠输入模型。第一版优先使用元素暴露的 AT-SPI action、EditableText 和 Value 接口；coordinate `click` / `drag` 与 `press_key` 使用 AT-SPI event synthesis fallback，在 Wayland 下只能按 best-effort 处理。`press_key` 的具名键以 keysym 配合 `KeySynthType.SYM` 发送，修饰键以 X modifier mask 配合 `LOCKMODIFIERS` / `UNLOCKMODIFIERS` 保持；`PRESS` / `RELEASE` / `PRESSRELEASE` 只接受硬件 keycode，不能传 keysym。
- Linux runtime 需要运行在已登录桌面用户 session 里。缺少 `XDG_RUNTIME_DIR`、`DBUS_SESSION_BUS_ADDRESS` 或 display 环境时，Go runtime 会在启动 Python AT-SPI bridge 前尝试从 `/run/user/<uid>` 和常见桌面进程自动发现当前用户的 session bus、display / Wayland 值；纯 SSH tty 如果找不到已登录桌面 session，可以启动二进制，但不能直接 inspect 或操作 GUI session。
- `get_app_state` 的 accessibility tree 在 GTK/GNOME app 上可能很深，Linux bridge 使用与 macOS / Windows 一致的 1200 节点、64 层默认 tree budget，并支持显式提高 `max_tree_nodes` / `max_tree_depth`。截图通过 GDK root window best-effort capture；GNOME Wayland 可能返回黑图，bridge 会检测全黑采样并省略 image block。
- 这 9 个 tool 的协议面与 macOS / Windows 保持一致：`list_apps`、`get_app_state`、`click`、`perform_secondary_action`、`scroll`、`drag`、`type_text`、`press_key`、`set_value`。其中 element-targeted action 会优先复用上一轮 `get_app_state` 的 runtime path metadata，coordinate action 使用 screenshot/window-relative 坐标。
- Linux `click_method=accessibility` 映射到 AT-SPI action，`global` 映射到 AT-SPI mouse synthesis 并要求全局指针环境变量；AT-SPI 没有等价的进程定向 mouse dispatch，因此 `app_post` 和 macOS-only 的 `sky_click` 会在 snapshot lookup 前明确返回 unsupported，`key_method=sky_key` 也一样。`auto` 仍保持 AT-SPI action 优先、mouse synthesis fallback 的现有行为。
- 当前 Linux 侧仍是功能性第一版：没有 visual cursor overlay、没有 installer/desktop entry，也没有独立 Linux fixture。后续 TODO 记录在 `docs/exec-plans/active/20260422-linux-computer-use-runtime.md`。

## 关键边界

- 开源版当前不复刻官方闭源实现里的 caller signing、私有 IPC、完整 overlay choreography 和 plugin 自安装逻辑。
- 因为官方 `SkyComputerUseClient` 带有宿主侧 launch constraints，普通 stdio MCP client 在本机上可能被系统直接杀掉；如果要探测官方 bundled `computer-use`，`scripts/computer-use-cli` 的 app-server 模式现在只适合做工具清单和协议面观察。官方 `1.0.755` 的真实 tool call 还会经过 service-side sender authorization / active IPC client 追踪，外部 raw helper 即使走已签名 Codex binary，也可能返回 `Sender process is not authenticated`；需要真实使用官方工具时应走正常 Codex agent/tool 调用链，开源版则继续提供可直连的 `open-computer-use` MCP server。
- 当前权限引导已经具备可运行 app、深链、拖拽辅助，以及一版更接近官方的 accessory panel 入场动画和返回 affordance；点击链路也已经补上独立 visual cursor、官方 asset fallback 和相对目标 window 的排序逻辑，并且在 overlay 可见期间会持续重申“排在目标 window 之上”，避免用户手动激活目标 app 后 cursor 被目标窗口重新盖住；但整体还没有完全复刻官方那套嵌入式 choreography / host 集成 / session approval 体验。
- screenshot 当前通过 `ScreenCaptureKit` 捕获目标窗口，并以 MCP `image` content block 的 base64 PNG（默认）或配置的 JPG/WebP 返回，不再把普通 app 截图落盘到仓库或临时目录；编码前会按配置的最大长边等比例缩小，或按超限策略与最小总像素数门槛省略截图，同时 coordinate tools 继续按实际返回的 screenshot pixel 尺寸映射坐标；单次 ScreenCaptureKit capture 会设置超时，超时后省略 image block 而不是卡住整个 `get_app_state`。
- 会话状态现在是进程内内存态，保存每个 app 最近一次 snapshot 和 element index 映射。

## 主要验证路径

- 单元测试：`swift test`
- JS REPL 与 CLI contract：`node --test scripts/node-repl/*.test.mjs`
- standalone cursor 构建：`swift build --product StandaloneCursor`
- cursor lab 构建：`swift build --product CursorMotion`
- 端到端 smoke：`./scripts/run-tool-smoke-tests.sh`（标准 9-tool smoke + visual cursor idle smoke；脚本默认以 headless 模式启动内部 fixture，避免在用户桌面弹出测试窗口）
- app 打包：`./scripts/build-open-computer-use-app.sh debug`
- 权限 onboarding 端到端回归：`./scripts/run-permission-onboarding-e2e.sh`（需要当前 macOS 对被测 `open-computer-use` 已授予 Accessibility 与 Screen Recording；默认禁用 app-agent proxy 来测试当前 CLI 运行态，可用 `OPEN_COMPUTER_USE_E2E_CLI=/path/to/open-computer-use` 指定被测 CLI，或用 `OPEN_COMPUTER_USE_E2E_DISABLE_APP_AGENT_PROXY=0` 显式覆盖默认代理行为）
- npm staging：`node ./scripts/npm/build-packages.mjs`
- release tgz：`./scripts/release-package.sh`
- skill 打包：`npm run package:skill`
- Windows runtime 单测：`(cd apps/OpenComputerUseWindows && go test ./...)`
- Windows exe 构建：`./scripts/build-open-computer-use-windows.sh --arch arm64`
- Linux runtime 单测：`(cd apps/OpenComputerUseLinux && go test ./...)`
- Linux binary 构建：`./scripts/build-open-computer-use-linux.sh --arch arm64`
- 对比样本：`artifacts/tool-comparisons/20260417-focus-behavior/`
- 手工诊断：
  - `open-computer-use doctor`
  - `open-computer-use snapshot <app>`
  - `open-computer-use call list_apps`
  - `open-computer-use call --calls '[{"tool":"get_app_state","args":{"app":"TextEdit"}}]'`

## 用户配置

macOS screenshot 在每轮捕获读取用户 JSON 配置，优先级为 ENV > 文件 > 默认值。npm launcher 提供 `ocu config` 查看、set、reset 和 path；支持 PNG/JPG/WebP、JPEG 质量、最大长边/超限缩小策略、最小总像素数丢弃与 SCK 超时，保留 hardware capture 优先路径。app-agent 按请求转发解析后的配置路径并清除未提供的 image 环境，防止常驻值污染。见[中文配置说明](configuration.zh-CN.md)与[English](configuration.md)。

截图像素丢弃门槛按 width×height 计算，低于（不含等于）门槛不返回 image，但保留 AX 和原因；配置省略截图后拒绝坐标输入。WebP 无损编码通过固定版本 libwebp 静态链接，随 app/npm 制品带上许可文本。

## 定向 AX 查询

macOS 在原有 9 个工具之外新增 `query`，按文字或角色查找目标窗口的 AX 元素，不截图、不渲染完整树。Windows/Linux 保持原来的 9 个工具。查询只解析已运行的应用，使用有界 BFS（默认 500 个节点、最多 5000 个，2 秒协作式遍历截止时间），返回匹配项和完整性元数据。字符串和子节点分页同样有界，AX 读取错误会标记结果不完整。

查询索引属于当前 native 会话，最多保留 5000 个、120 秒过期，结束会话时清理且永不复用。元素操作前核对进程身份、窗口归属、查询条件和最新几何；任何验证失败都要求重新查询，不使用旧坐标。JS `cua.getApp(name, { initialState: false })` 可跳过初始快照，`app.query()` 返回结构化结果。详见[查询说明](targeted-query.zh-CN.md)。

## Fork 的坐标点击修正

macOS 坐标 `auto` 点击只对实时命中、属于当前窗口且包含点击点的直接控件执行 AXPress（右键为 AXShowMenu）。不会搜索根窗口的可点击后代，也不会选择祖先列表项。窗口有效性独立通过 WindowServer 校验：ID、PID 和几何保持一致，进程未隐藏；同 App、同 Space 的上层窗口不能遮挡点击点。定向输入允许其他 App 覆盖与其他 Space，只有 global 额外要求 on-screen。AX 可选命中查询无值、不支持、未实现、通信失败或元素失效时，可在独立窗口复验后走鼠标；权限关闭、非法参数与未知错误拒绝输入。AX 窗口归属未知只走鼠标，明确不匹配则拒绝。鼠标左键单击/双击与右键单击使用 sky_click，其余沿 app_post；显式开启全局指针时走 global，并要求点击点不被其他 App 遮挡。窗口在查询前和发送输入前各验证一次。AX 或鼠标发出后失败不换路重放，坐标 auto 回读只读，不激活/重开窗口。元素索引有效 AX 点击和显式定向点击保留；前台鼠标点击按下文专用策略执行。hit test 使用窗口局部坐标加窗口原点，截图缩放仅发生一次。

后台坐标校验不从 `.optionAll` 的数组位置推断窗口层级；完整集合只查目标身份。屏上目标通过 `.optionOnScreenAboveWindow + .optionIncludingWindow` 取得上层候选并重验目标；离屏目标通过 `.optionOnScreenOnly` 检查相关屏上候选，再单独刷新目标身份。只有同 App、可见且覆盖落点的候选需要 Space 信息；明确不同 Space 放行，同 Space 但离屏目标层级不可证明则明确失败。该查询在后台分支惰性执行，激活前 identityOnly 与前台实际接收窗口检查不依赖它。app_post 的 AX 查询前后分别取得新证据，不跨阶段缓存。

相关回归位于 `CoordinateClickTests.swift`、`CoordinateWindowTests.swift` 与 `CoordinateWindowQueryTests.swift`；真实第三方 App 的命中结果和鼠标投递效果仍需 GUI 验收。

sky_click 和 app_post 均允许后台定向输入。后台模式的 app_post 在可选 AX focused-window 查询前后验证 PID、窗口 ID、几何与同 App 遮挡；已知 focused window 不匹配则拒绝，AX 信息不可用不单独阻断。它不要求目标占据系统前台，也不主动激活；PID-only 事件仍无法保证应用实际接收，必须观察效果。

### 输入诊断

click MCP 回执中的 `_meta.ocuDiagnostic` 关联 `ai.today.ocu / input` 的 OSLog notice。同步调用范围内记录坐标映射、窗口校验、选路和事件发送步骤，仅保留数字和固定状态标签。returned 表示调用返回，输入效果仍为 unverified；日志不证明目标应用消费了事件。宿主不必捕获可能含正文的 stderr。

### 点击专用前台策略

宿主可设置 `OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE=foreground`，仅启用点击的全局 HID 路径。`auto` 仍先使用可靠命中控件的 AX 动作；需要鼠标时，绑定快照中的准确窗口，激活后重新检查前台窗口、几何、Space 和点击点遮挡。失效则要求重新观察，不自动重试。此开关不启用全局滚动或拖拽，也不改变显式 `sky_click` / `app_post` 的选择。

窗口准备只允许 AXRaise 绑定窗口及必要的 App 激活，不使用 `activateAllWindows`。有效后台 AX 动作与观察无需为此激活 App。事件投递成功仍需调用方观察实际界面结果。

普通观察（`get_app_state.initialize=false`）只解析运行中进程并使用只读恢复策略；启动与重开仅在绑定阶段执行。窗口尚未注册时，仅对明确的无窗口错误最多等待五次 100ms 后再读，不调用 activate/raise/open 恢复。隐藏、最小化、无可观察窗口会明确失败；普通动作回读同样不执行激活恢复。观察失败会废弃该目标所有别名的输入快照；输入缓存缺失时必须先显式观察，不能隐式刷新后继续输入。后台能力不等于保证目标 App 自身永不改变焦点。

### 复审修正：未知动作、实际接收窗口与失效快照

- 元素索引路径只有动作未列于可用 AX actions 时才允许继续选路；一旦调用 AX，非成功回执终止本次输入，包括重复动作的中途失败，不再尝试候选元素或 HID。
- 前台点击最终以 `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` 确认 mouse-down 实际接收窗口，查询使用转换后的 AppKit 屏幕坐标并从最上层开始。它按系统命中规则跳过透明区域和忽略鼠标事件的窗口，不按 Dock/helper 进程放行。返回空、其他窗口或无法映射屏幕时拒绝输入；ID、PID、几何和前台焦点检查保留。后台定向输入仍保留同 App/同 Space 遮挡检查。
- AppKit API 依据：[Apple 鼠标按下命中查询文档](https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:))。这些自动化回归不代替腾讯会议、Dock 和多显示器的真实界面验收。

## 应用绑定与观察

macOS 应用名称解析保留路径、bundle ID 和运行名称的既有优先级；未命中时，先检查正在运行的用户应用安装包，再检查标准安装目录。名称候选来自 `.app` 文件名、`CFBundleName` / `CFBundleDisplayName`、各语言 `InfoPlist.strings` 和按语言分组的 `InfoPlist.loctable`，不受系统当前语言限制。匹配仅规范化大小写、Unicode 和 `.app` 后缀，不猜测翻译或模糊前缀；未声明的别名仍可能查不到。新增名称匹配出现多个实际安装路径时返回歧义和候选身份，要求明确 bundle ID 或路径；同一包的符号链接去重，内嵌 helper 不作为独立应用发现。解析只读，安全策略、单次打开与失败后不重放规则不变。`list_apps` 仍是运行及近期应用视图，不代表完整安装列表。

`cua.getApp(nameOrBundleID)` 在一次 `get_app_state(initialize=true)` 调用内完成绑定：已有窗口直接返回；未运行时后台启动；已有进程但有界观察后仍明确无窗口时，通过 NSWorkspace 后台 reopen 一次。回调的实际 PID、bundle 身份用于后续快照，不再根据安装包名重新猜测进程。打开后仅重试只读观察，不重发打开操作；权限或其他错误保持原错误，不触发 reopen。打开不保证创建文档，模型必须根据返回的打开面板或窗口继续操作。

绑定对象的 `getAXState` / `getScreenshot` / `getAXStateAndScreenshot` 明确发送 `initialize=false`；动作回读也只观察。原生 MCP 工具与 CLI snapshot 默认初始化，兼容直接使用原生入口启动目标的路径。系统配置 `activates=false` 且不新建应用实例；这只表示不主动要求前台激活，不保证第三方应用自己不会改变焦点。

打开前先只读定位安装目标，得到固定的 bundle ID（缺失时使用规范 bundle 路径），再登记待恢复状态并发送一次打开请求。回调结果未知或打开后的观察失败均保留该状态；首次 getApp 未返回绑定时，可再次 getApp 继续观察，同一目标换名称、bundle ID 或路径也不能重放打开。成功观察只解除对应目标的状态，同名但不同 bundle 的应用互不干扰。安装查找失败发生在登记与发送之前，不会阻止安装后重试。初始化只失效目标应用的输入快照，不清空其他应用缓存。

该接口行为依据 Codex 实际工具实验：Calculator/Chess 未运行时 getApp 可启动，TextEdit 关闭打开面板后普通观察失败，重新 getApp 恢复打开面板。官方内部是否使用 NSWorkspace 及其 PID 管理方式无法由实验确认。本 fork 实现不宣称复制其内部代码；最小化、隐藏与抢前台行为仍需独立验收。

### 后台输入默认与显式兼容路径

`OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE=background` 让 auto 的鼠标分支保持后台优先，即使显式前台点击已获授权也不改变默认路由。`OPEN_COMPUTER_USE_ALLOW_FOREGROUND_CLICKS=1` 只允许调用者显式使用 global 点击，不扩大滚动或拖拽权限。元素和坐标的鼠标分支共用窗口校验与选路；SkyLight 不支持的中键或多击使用窗口验证后的 app_post；不保证所有应用响应此路径。

自动动作回读关闭时，键盘仍实时检查接收者，不能使用点击前缓存的焦点。动作返回不证明输入已被应用消费；模型应在一轮 JS 的末尾显式观察并核对结果。后台键盘与真实鼠标是否不干扰用户，仍须对目标 App 做验收。这里复用上游 SkyLight 实现，不宣称复制闭源 Codex 的内部调用栈。

文本按 Unicode 分块投递时，每块开始前重新核对同一个实时接收者；中途失效报告可能已有部分输入并停止，不重放全文。可编辑 ComboBox 必须有实时 editable 或 value-settable 证据；显式只读或禁用的文本控件拒绝输入。部分应用不暴露只读属性时，文本角色仅作为候选证据，最终结果仍需观察确认。

文稿窗口的 AXDocument URL 直接展示在 AXWindow 观察中，避免仅为核对原路径打开重命名/移动面板；不读取文件、不推断缺失 URL，AXWebArea 的 URL 行为不变。

### 宿主严格后台契约

`OPEN_COMPUTER_USE_EXECUTION_MODE=background` 是执行策略，优先于所有旧 foreground/global/hover 开关。未设置保持兼容；空字符串或未知值在执行入口拒绝，不能默认为兼容。共用 `ExecutionPolicy.current()` 解析，SkyLight 后台准备与后台键盘仍可使用该策略。

严格模式禁止 global 点击、移动真实鼠标的 hover、popup global 点击、显式 AXRaise、accessibility 的 activation-only fallback、快照 activate/unhide/raise/open 恢复，以及 global 滚动拖拽。显式 accessibility 的普通 AX 语义动作仍可执行；auto 坐标的 AX/SkyLight 路径和后台焦点恢复保留。初始化仍可使用既有 activates=false 的单次后台启动契约。

`postToPid` 本身不等于抢前台。后台模式下点击、滚轮和拖拽统一保留进程/窗口身份、几何和同 App 遮挡验证；focused-window 是可选证据，只拒绝已知冲突。目标自然进入前台不再中断后续已验证输入，也不强制切回。后台策略禁止 fork 主动 Raise/global/真实 hover，不承诺第三方 App 不改变前台。输入失败不切换 global、不重放。PID 定向投递不保证窗口服务器拖拽等交互成功。

`hover(observe_only=true)` 是 native 只读弹层观察入口，不受严格后台或旧 hover 输入开关限制；必须已有有效绑定快照，回读仍为 readOnly，不启动应用。未知执行模式照常拒绝。输入 hover 在严格后台拒绝且不出现在工具列表中；显式 native 调用只读分支不依赖该列表。dispatcher 不为只读请求切换 input-active 状态。

### 2026-10-11 可选 AX 查询与显式输入

显式 `sky_key` / `paste_text` 以当前进程和 WindowServer 窗口身份为输入前置条件，AX 文本焦点缺失不构成否决。`auto` 仍要求实时可编辑接收者；保留插入点/选区语义，不恢复上游旧的 `AXValue(base+text)` 拼接。菜单查询仅为可选优化：查询不可用时重新验证目标再发送 PID key；AXPress 一旦尝试，错误不允许 key fallback。自然前台变化不会中断输入；窗口改变、权限错误和未知提交结果仍停止。详见 [输入策略对齐计划](exec-plans/completed/20261011-input-policy-parity.md)。

### 粘贴结算与生产分派回归

paste_text 提交后保留新剪贴板内容，不用任意读取者回执触发恢复，也不定时恢复旧数据。仅菜单/键盘动作尝试之前失败才在仍持有所有权时恢复原格式；提交后错误标记未知结果，不重放。此副作用在工具 schema 和 JS 文档明确说明。SkyKeyboardDeliveryBackend 只注入系统查询/SPI 边界，测试直接执行 SkyKeyboardDispatcher.deliver 的真实前后台分支，覆盖自然前台变化、窗口失效与清理。

JS 的 click / pressKey / typeText 在 native 请求前拒绝未知 options 字段、无效按键/次数/方法。组合键使用 `pressKey("super+s")`；`modifiers`、`durationMs` 和拼错的 `button` 不再静默忽略。详见[后台右键验收](histories/2026-10/20261011-1730-background-right-click.md)。

### 宿主单次前台兼容入口

构造 `ComputerUseService(allowsForegroundClickOnce: true)` 可在严格后台会话额外提供 `click_foreground_once`；默认构造不开放。此入口消费最近一次显式观察，只允许同 app、30 秒内截图上的一次左键。它使用既有窗口校验和 HID 点击，通过局部类型化授权允许该次窗口准备及点击，不修改环境变量，也不影响 `auto`、键盘、滚动、拖拽或快照恢复。操作前使缓存输入快照失效，后续必须再次观察；失败或未知结果不自动换路重放。模型需确认这是打开 UI 的非提交入口；`purpose:open_control` 本身不证明控件语义。详见[本轮记录](histories/2026-10/20261011-1835-single-foreground-click.md)。

单次入口的失败诊断区分策略、目标校验、激活、接收窗口校验及 HID 投递阶段。错误结果与原生日志输出稳定阶段码、白名单错误类别，以及 activation/input may-have-occurred 标记；不转发任意错误正文。进入投递阶段后保守报告未知效果，之前的失败明确没有 HID 输入，但激活阶段及之后仍可能改变前台。所有失败均要求重新观察，不自动重放。
