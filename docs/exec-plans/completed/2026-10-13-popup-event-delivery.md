# 弹层选色事件对照

## 目标与范围

复现 WPS 色板点击返回成功但标题未变色的问题，隔离事件序列与投递通道。只调整凭证绑定弹层的定向点击；普通窗口、右键、焦点策略、截图与云端协议不变。

## 约束

保留单次 token、TTL、root/popup 身份及坐标、接收窗口复验。结果不明不能自动重放；不能自动切换前台 HID。Helper 退出由用户手动触发，不计为故障。

## 实验记录

2026-10-13，独立 AppKit MCP 实验宿主，WPS 的已选中标题：

| 组别 | 序列 | 通道 | 实际结果 |
| --- | --- | --- | --- |
| A | moved、primer down/up、target down/up | SkyLight + public PID | 色板关闭，标题仍蓝色 |
| B | moved、target down/up | 双通道 | 色板关闭，标题仍蓝色 |
| C | 同 B | public PID | 标题变红，正文保持黑色 |
| D | 同 B | SkyLight | 标题从红色变为选定蓝色 |

B/C 的序列及时序相同，仅通道变化；D 选蓝色以观察实际颜色改变。以上是机制验证，不是 Today App→云端→Helper 验收。字体对话框 public PID 单通道成功将色块与预览改红；确认按钮触发缺失字体提示，下一次观察文档已呈红色，该确认过程不计入无人干预验收。最终无实验开关构建以 SkyLight 单通道将 Font 预览从红改蓝，取消后文档仍为红色。

## 决策与风险

弹层使用单次 SkyLight 定向投递，不发送窗口外 primer；默认普通窗口保留原事件和双通道。没有 WPS bundle 特判。单次成功不代表其他应用全覆盖，仍需单元回归及第二入口验证。

## 进度

- [x] 基线与两个单通道对照。
- [x] 清理实验开关，验证最终实现和安全门。
- [x] 字体对话框入口验证、完整 diff 复审及记录。

## 验证结果与边界

- `swift build --product OpenComputerUse` 及最终测试构建通过。
- `swift test --filter 'SkyClick|Popup'`：XCTest 68 项（1 个显式 live 测试跳过），Swift Testing 21 项，无失败。
- 独立只读复审未发现 P1/P2；`git diff --check`、文档检查通过。
- SwiftLint 的 3 个 error 在 HEAD 基线同样存在（InputSimulation 的强转及两条长行）；未扩展本次范围去清理。SwiftFormat 按现有文件局部风格处理，避免引入整文件重排。
- `make check-repo` 的 hygiene 阶段被仓库原有缺失模板/工作流文件阻断；文档阶段通过。
- 未修改 Today pin、未替换 App、未提交推送；云端→Today Helper 整链路和其他应用弹层尚未验收。
- WPS 已还原为文档主窗，标题红色、正文黑色，未导出 PDF。

用户指定工具栏常用入口后，用最终无实验开关构建再次验证：打开 Home 字体颜色下拉，单通道选蓝后标题蓝色；重新观察并打开，再选红后标题红色。两轮独立截图确认正文仍黑色。打开下拉使用显式单次前台点击；色块选择使用凭证绑定的后台 SkyLight 定向事件，不能称为全程后台。
