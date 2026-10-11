## [2026-10-11 14:15] | Task: 修复 AX 缺失时的显式后台输入

### Execution Context

- Agent: Codex，当前桌面任务；未使用并行子代理。
- Runtime: macOS Swift Package / Node。

### User Query

修复网易云后台输入失败，并 review 与上游 OCU 和 Codex 实测行为是否对齐。

### Changes Overview

- `ComputerUseService.swift` / `KeyboardReceiver.swift` 分离显式窗口验证和默认 AX 焦点验证。
- `SkyKeyboardSimulation.swift` 复用菜单/按键派发，粘贴完整包裹在合成焦点内。
- 新 `ClipboardInput.swift` 保存多格式剪贴板、等待读取回执、有条件恢复、不重放未知结果。
- dispatcher/schema/JS 增加仅纯文本 `paste_text` / `app.paste`。
- Swift 与 Node 回归覆盖缺失 AX、失效窗口、剪贴板竞争、失败恢复、未知结果和中文参数。

### Design Intent

显式 `sky_key` 对齐上游 `3cfe4b1` 的无 AX 文本焦点要求；保留 fork 的默认 `auto` 防护。
粘贴是独立扩展，契合 Codex 已观测行为，不宣称等同闭源实现。
截图、普通 agent 图像输出、前台政策不改。

### Validation And Review

- fork 全量 Swift：378 项 XCTest（7 项 opt-in 跳过），0 失败；Swift Testing 12 项通过。
- 随后补充部分暂存失败恢复与工作线程约束，42 项定向回归全部通过。
- fork Node 43 项，Today Node 86 项；Today helper 用临时本地 dependency override 编译成功。
- 复审修复固定等待导致剪贴板过早恢复、合成焦点早退、partial-stage 恢复与主线程回调等待。
- 真实命名剪贴板验证有效 RTF 与 Unicode 数据往返；fake store 验证并发复制和无重放。
- 不提交、不推送、不改变远程 pin、不部署。真实 App GUI 尚未验收。
- 剪贴板共享状态无 CAS、读取回执非目标编辑成功证明，限制已写入设计说明。

### 后续输入策略复审修复

- 移除目标自然进入前台导致中止的条件；可选 AX 菜单/命中查询失败允许窗口验证后的定向路径。
- app_post 不强制系统前台或 AX 焦点，保留已知接收者冲突与窗口身份检查；查询前后复验。
- 默认 auto 的可编辑检查、插入点语义、权限与未知结果不重放保持；paste 仍是 Today 扩展。
- 更新当前架构和 Today guidance，移除断言错误的前台限制；新增上游核心文件只读校验脚本。
- 完整 Swift 382 项 XCTest（7 跳过、0 失败）+12 项 Swift Testing；最后测试结构整理后相关 41 项通过；fork Node 43、Today Node 87 通过。
- Today helper 临时 override 集成编译和 just check 通过，override 已移除；远程 pin 与运行 App 未变。
- 复审详见完成计划。真实 GUI 与 App→lane→helper 验收未执行，微信仍暂停。

### 发布前最终两项修复

- 再次复审发现任意剪贴板读取会提前触发恢复，已改为输入提交后保留新文本；仅提交前失败恢复原格式。工具与 Today guidance 同步说明副作用。
- SkyKeyboardDeliveryBackend 注入真实分派的系统边界，回归直接调用生产 SkyKeyboardDispatcher，覆盖自然前台变化、已前台路径、部分输入后窗口失效与清理。
- 完整 Swift 383 XCTest（7 跳过、0 失败）+12 Swift Testing；fork Node43、Today Node87通过。早期“读取回执后恢复”的设计及验收结论由本段取代。
- 用户已授权发布 fork、更新 pin、运行 App 与对应验收；实际发布及真实验收结果另记。
