## [2026-10-12] | Task: 修复独立弹层观测盲区

### Execution Context
- Agent: Codex desktop，主代理与三个分工代理；模型配置沿用当前会话。
- 工作分支：fix/wps-popup-observation；基线 2810a9419984b09a6ab99fbecc42a79782371345。

### User Query
按照自己的方案修复 WPS New 面板真实可见、模型截图及画中画遗漏的问题。

### Changes Overview
- 普通快照自动附同进程关联弹层独立图片，保留主图坐标和相邻说明。
- 后台弹层显式 sky_click，单次 token 绑定 root/popup/几何/TTL/接收窗口；拒绝自动路由、遮挡和重放。
- PIP 保留 root 实时流，有界采集及合成关联弹层；跨 Space／隐藏只撤销弹层，root 关闭才停止预览。静止画面下的窗口平移重绘光标坐标，保留黑底及尺寸约束。
- 普通附加观察 200ms、显式观察 800ms，包含 AX 与截图总预算。进程内单个采集槽位在系统调用真正结束后释放，迟到结果不生成 token。
- Today JS 输出保留多图顺序，主图缺失不冒充主图；源工作区和 Electron 镜像同步。

### Validation
- 原生完整回归：445 XCTest（7 live 测试按默认配置跳过），43 Swift Testing 通过。
- Swift 构建通过；TodayOCUHelper 通过临时 path 依赖接入当前 fork 编译。临时目录不参与正式 pin 或打包。
- 前轮 Today/Electron runtime 110 项、Electron 打包回归 24 项通过；本轮 JS 批次输出最终复审及发布 pin 集成结果另记源包交付记录。52 文件镜像逐字节校验与 Today 源仓 just check 已通过。
- SkyClick 内部锁等待、焦点准备、primer 之后继续复验；receiver 查询后再核对实时窗口几何与 TTL。新增回归覆盖同 ID 移位、超时和输入未知结果不重放；普通 SkyClick 事件序列保持原样。
- 原生代码完整回归与独立复审完成，无未解决的 P1/P2；JS 最终结算与仓库间发布在依赖层分别验证。
- docs check 通过；check-repo 因基线缺少 .editorconfig、.github 配置和 .markdownlint.json 失败，没有扩大修复范围。
- 本提交合并前轮 WPS 原生修复与本轮生命周期、预算、复验修正，随后由 Today/Electron 固定本提交。重建签名 App、WPS／跨 Space 真实验收不在本次代码交付内；不宣称真实任务已成功。

### Design Intent
同 PID 与几何邻近仅用于候选观察，不证明父子所有权。执行要求模型选择明确图中目标，设备端再次验证精确接收窗口。不会把普通后台动作自动升级为全局 HID。
