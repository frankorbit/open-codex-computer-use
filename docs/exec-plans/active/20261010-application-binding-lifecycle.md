# 应用绑定与观察生命周期

## 目标与决策

对齐 Codex 实测的 `cua.getApp` 行为，撤回尚未发布的强制 `open_app` / `cua.openApp` 方案。
绑定负责必要的后台启动或无窗口 reopen，绑定后的普通观察不重复启动。不自动创建文档、不重放输入。

## 实证与边界

- Codex 工具文档说明 getApp 可后台启动应用；实测 Calculator、Chess 冷启动成功。
- TextEdit 关闭打开面板后普通观察返回 noWindowsAvailable，重新 getApp 恢复面板。
- 这些结果不证明官方内部系统 API，也未证明最小化或前台焦点行为。
- 上游 `3cfe4b1e52cad6a99f5f19a7e01fb279752eb2a8` 默认恢复会 unhide、activateAllWindows、open、AXRaise；本次不恢复每次观察都激活的做法。

## 实现

- JS getApp 传 initialize=true；绑定对象观察传 false，不增加模型工具。
- 原生工具/CLI 默认初始化；已有窗口直接读，仅明确无进程/无窗口才一次后台打开。
- 使用系统回调的真实应用身份；回读只重试 no-window，其他错误直接返回。
- 打开前废弃旧输入快照与 popup token；新观察成功后才允许输入。
- 仅失效目标快照；先定位固定安装身份，再登记 pending 并打开，避免影响其他应用或通过别名重复初始化。
- 首次绑定失败后可再次 getApp 只读恢复；成功观察仅清除对应目标 pending，同名不同 bundle 不互相迁移状态。
- 保留窗口错误分类修复，不将 cgWindowNotFound 误报成权限拒绝。

## 验证与交付

- [x] 原生生命周期回归覆盖冷启动、无窗口、已有窗口、权限错误、单次打开及旧快照失效。
- [x] JS 与 native runtime 参数/输出/工具数量回归。
- [x] 前轮原生生命周期与快照回归 38 项通过；本地 fork 的 Today Helper 集成编译通过。
- [x] 后续复审补齐全量失效与首次绑定失败恢复，并修正未知结果跨别名重放、同名目标 pending 污染。
- [x] 最终原生定向回归 48 项、fork Node 40 项、Today runtime 49 项通过；本地依赖 Helper 编译、SwiftLint、Today just check 通过。最终只读复审无新增明确 P1/P2。
- [ ] 发布 fork revision、更新 Today pin、App 构建及 lane 真实验收；本轮不提交或发布。
