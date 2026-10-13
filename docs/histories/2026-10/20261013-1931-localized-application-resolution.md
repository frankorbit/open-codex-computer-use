## [2026-10-13 19:31] | Task: 通用多语言应用名称解析

### 🤖 Execution Context
* **Agent ID**: 当前 Codex 会话
* **Base Model**: GPT-6
* **Runtime**: Codex desktop，本机 macOS

### 📥 User Query
> 英文系统使用中文名称打开已安装应用时查找失败，开始做通用修复。

### 🛠 Changes Overview
**Scope:** OpenComputerUseKit 的 macOS 应用发现层。

- 从仅匹配安装文件名扩展为读取安装包基础名称和全部语言的声明名称，支持 `InfoPlist.strings` 与 `InfoPlist.loctable`。
- 运行中的用户应用先在自身安装包中解析别名，未命中才遍历原有标准安装目录；保留路径、bundle ID、运行名的原有优先级。
- 新解析器对多个实际安装路径返回歧义；合并符号链接，但保留链接文件名；排除嵌套 helper。
- 把查找闭包改为可抛出，使歧义不会被吞成“未安装”，也不会触发打开。含点号但未匹配 bundle ID 的查询继续匹配名称。
- 增加 15 项测试入口，覆盖多语言、Unicode、资源格式与损坏、歧义、符号链接、运行身份、安全限制和只读实机探针。

### 🧠 Design Intent (Why)
英文系统不代表应用中文名称不可用。应从应用自身元数据建立同一身份的名称集合，避免为单个产品硬编码英文名或让模型猜译。系统应用只读验证发现 `loctable` 形式，补齐后计算器与 Finder 的中文查询通过。

### Validation and Review
- 全量 `swift test`：527 项 XCTest，8 项按环境跳过，0 失败；另有 65 项 Swift Testing 通过。
- 显式只读探针确认“网易云音乐”“计算器”“访达”解析到各自正确 bundle ID；不会启动或激活应用。若应用正在运行，同时验证中文别名绑定无需回退到完整安装扫描。
- 两个新增 Swift 文件通过 SwiftFormat 和 SwiftLint。原 `AppDiscovery` 的全文 lint 仍有既存行数、逗号等债务；与 HEAD 对比无新增违规。
- 复审名称规范化、重名拒绝、身份与路径核对、解析错误传播、权限检查以及打开前后的边界；不改鼠标、键盘、弹层、预览和打开回执机制。

### Limits and Delivery
- 无翻译词典或模糊猜测；应用未声明的名称不能保证命中。未运行且不在标准目录内的应用仍需已注册 bundle ID 或明确路径。
- `list_apps` 的范围与模型规划策略未修改；该列表缺项不能证明应用未安装。
- 完成源码与只读验证后，用户要求提交推送并更新 Today pin；按依赖先发布、宿主后固定 revision 的顺序交付。Today 实际启动和音乐播放由用户验收。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InstalledApplicationResolver.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/InstalledApplicationResolverTests.swift`
- `docs/ARCHITECTURE.md`
