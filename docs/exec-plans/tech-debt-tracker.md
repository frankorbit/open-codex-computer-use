# 技术债追踪

这里记录那些暂时不阻塞当前任务、但已经值得留档的技术债。

| 日期 | 区域 | 债务描述 | 为什么会存在 | 计划中的后续动作 |
| --- | --- | --- | --- | --- |
| 2026-10-17 | 重复截图 | 请求截图时仍会返回未变化的画面。 | #101 的显式采集开关在本 fork 只移植了 macOS；相同图像省略是独立能力。 | 评估按会话 / 应用 / 窗口隔离的精确图像去重；首帧、重置与强制返回必须明确，不能用 AX 未变推断画面未变，也不把去重当成跳过截图采集。 |
| 2026-04-17 | 普通 app AX snapshot | Finder 路径已经能拿到前台窗口子树并输出 window-relative frame，但当前还缺更多真实 app 回归样本，无法证明这套 rooting / traversal 对复杂 app 都稳定。 | 这一轮先把 Finder 这类真实 app 的坐标换算和窗口子树收敛好，再把 deterministic 回归继续留给 fixture。 | 增加 Safari / System Settings / Activity Monitor 等真实 app 样本验证，并继续收敛 `kAXMainWindowAttribute`、focused element parent chain 和多窗口回退策略。 |
