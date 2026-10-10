# 应用绑定与普通观察分离

## 用户诉求

按 Codex 官方工具的实际使用方式修复 TextEdit 无窗口失败，确认是否撤回先前显式 openApp 方案。

## 实证与决策

官方工具实验中，Calculator/Chess 未运行时 getApp 能启动并返回界面；TextEdit 关闭打开面板后普通观察返回 noWindowsAvailable，重新 getApp 恢复面板。该实验未验证官方内部系统 API、最小化状态或前台焦点行为。

撤回尚未发布的 open_app / cua.openApp 扩展，保留 getApp 作为唯一模型侧绑定入口。保留既有点击、hover、画中画与后台观察策略。

## 实现

- JS getApp 单次发送 get_app_state(initialize=true)，输出文本和可选图片后建立绑定。
- 绑定对象的三种观察方法显式 initialize=false，不能因观察失败隐式重开。
- 原生 MCP 默认初始化，CLI snapshot 显式初始化；显式窗口 placement 默认不初始化。
- 有窗口时直接读，仅无运行进程或持续无窗口时发一次后台 NSWorkspace 打开请求。仅重试无窗口观察，不重复打开，也不将权限错误当成恢复条件。
- 使用系统回调实际 PID、应用身份；后续安装名称与运行名不同时，只读解析 bundle ID 匹配进程。
- 打开前失效旧输入快照与 popup token，只有成功新观察可恢复输入。
- Today runtime 同步参数及文件 hash；已有窗口错误分类修复继续保留。

## 主要文件

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/ApplicationOpeningTests.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`
- `scripts/node-repl/binding-lifecycle.test.mjs`

## 验证

- 原生生命周期、快照失效、hover、工具数量及启动配置：38 项通过。
- fork JS adapter 与生命周期：24 项通过；Today runtime：47 项通过。
- Today Helper 在临时本地依赖包中集成当前 fork，编译通过；未改变工程依赖 pin。
- 独立静态复审：placement 默认值和安装名称别名问题均已修复，无阻断项。
- 尚未提交、推送、更新发布 pin 或重新编译主 App；新实现的真实 App→lane 验收仍待交付后进行。

## 后续复审修复

- 初始化不再全量清空快照，只失效目标应用，其他应用保持可用。
- 打开拆为只读定位和执行，发送前以固定 bundle ID／规范路径登记 pending，回调未知也不会丢失身份保护。
- 首次 getApp 失败后允许再次 getApp 继续只读观察，无需先拿到绑定；成功观察只解除同一目标的 pending。
- 回归覆盖其他应用缓存、首次失败恢复、未知结果跨名称／bundle ID／路径重复调用、同名不同 bundle 交错及查找失败后安装重试。
- 最终原生定向回归 48 项、fork Node 40 项、Today runtime 49 项通过；本地依赖 Helper 编译、SwiftLint、Today just check 和文档检查通过。独立静态复审无新增明确 P1/P2，未执行 GUI 验收。
