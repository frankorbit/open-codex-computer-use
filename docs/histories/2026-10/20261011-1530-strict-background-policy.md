# 会话级后台执行与复审

## 用户诉求与设计

修复 Today Computer Use 后续动作抢占前台与真实鼠标的问题，并深度检查跨 fork、native、cloud 的影响。后台启动不等于整个会话都在后台；后台策略必须覆盖显式前台输入与恢复路径。

`OPEN_COMPUTER_USE_EXECUTION_MODE=background` 由宿主设置，覆盖旧 foreground/global/hover 开关。未设置保留独立 OCU 兼容行为；未知模式拒绝执行。不是 full Node 沙箱，不宣称可以禁止任意自建进程绕过普通 cua API，也不宣称阻止第三方 App 自身主动激活。

## 改动

- 共用 ExecutionPolicy，覆盖 service/dispatcher、AXRaise、SnapshotBuilder 激活恢复、点击/hover/popup 派发及全局 HID 底层。
- 保留 AX、SkyLight、后台键盘和接收窗口验证后的后台滚轮。PID 点击/拖拽须已在前台的正确窗口；不主动激活，不自动换路重放。
- 合成焦点按准备、窗口 key、输入、释放阶段记录前台 PID 与鼠标位置；不记录正文、按键或窗口标题。
- 键盘准备后、每个文本分块前、菜单查询后检查后台目标是否变成前台。清理失败明确上报；已输入部分按未知结果处理，不重放。
- 将只读弹层观察与真实 hover/input token 分开，后台观察不附 global 点击指令，不给可消费的输入凭证。
- Today 固定 helper 环境并在 JS 请求前拒绝前台操作；cloud 指导在新截图中后台点击编辑区、核验焦点和输入结果。

## 复审发现及修正

1. 只在完整文本输入后检测前台状态，会继续发送剩余分块：改成每块及菜单提交前检查。
2. 原始环境字符串比较不一致：统一 ExecutionPolicy 解析。
3. hover 门禁误禁只读 popup：分离请求路径，并补 service/dispatcher 行为测试。
4. popup 底层采集仍要求前台、返回文案仍推荐 global：分离只读采集与输入授权，后台只返回观测说明。

## 验证与交付边界

详细自动化结果、隔离窗口实测和临时 override 清理状态见执行计划。本轮未更新依赖 pin、未提交推送、未部署 lane，也未替换正在运行的 Today。飞书真实账号的完整端云链路仍需新版本验收；最早一次前台切换的具体阶段需新诊断 trace 确认。
