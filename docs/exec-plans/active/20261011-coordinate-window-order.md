# 腾讯会议预约表单坐标拦截：检查与修复计划

状态：实现、定向回归与设备端腾讯会议表单验收已完成；最终记录见同日 history。真实跨 Space 和 App→lane 验收仍待完成。未提交或发布。

## 问题与证据

真实 Today Worker → helper 测试中，预约表单成功打开且主题可输入。日期按钮点击在投递前失败，诊断 F05F96A8-8685-4A0B-80C5-686D84A88B04 将预约窗口 60927 的点击点判为被同 PID 主窗口 60920 遮挡。没有 input_attempt，不能归因于腾讯会议拒绝了该次点击事件。

源码存在明确的顺序契约问题：ComputerUseService.validateCoordinateSnapshot 使用 CGWindowListCopyWindowInfo(.optionAll)，CoordinateWindow 随后将 windows[..<index] 当作上层窗口。Apple SDK 的 optionAll 只承诺包含会话的屏上/屏外窗口；optionOnScreenOnly 和 optionOnScreenAboveWindow 才明确承诺从前到后顺序。用前者数组下标推断遮挡缺少契约保证，存在误拒绝及漏拒绝风险。

当前本地 upstream/main 3cfe4b1e52cad6a99f5f19a7e01fb279752eb2a8 的 coveringWindowBounds 使用 optionOnScreenAboveWindow。CoordinateWindow 是 fork 的额外输入校验层，并非上游原有门禁。应对齐上游取得窗口层级的方式，但不照搬可见性辅助函数中的失败返回空数组：输入判定必须区分查询失败与确认无上层窗口。

旧日志没有记录当时的 AX→CG 精确映射结果、屏上列表、相对上层列表和实际鼠标接收窗口；单窗口截图不显示其他窗口遮挡。因此顺序契约缺陷已确认，但其是否为此次失败的唯一原因仍待实时证据确认。

## 实施顺序

1. **先复现并补充只读证据**。打开测试表单后记录 AX 窗口对应 CG ID、截图窗口 ID、窗口几何、前台 PID、all/onscreen/above 的 ID 顺序、候选窗口 Space 和该点实际接收窗口。仅记录标量，不记录标题、主题或账号。同步检查是否存在旧快照、窗口重新排序及 AX/CG 绑定漂移。不提交会议。
2. **拆分身份与遮挡证据**。all 数据只查 ID/PID/几何/可用性；屏上层级使用以目标 ID 为参照的 optionOnScreenAboveWindow，必要时用屏上列表核对目标可见性。接口显式区分完整窗口集合与已确认在上方的集合，禁止从完整集合的数组位置推断层级。激活前 identityOnly 和前台真实接收者校验不触发后台层级或 Space 查询；层级查询仅在后台分支惰性执行。
3. **保留后台与跨 Space 行为**。背景输入仍忽略其他 App 的覆盖，保留同 App/同 Space 真正上层窗口的保护。屏外/其他 Space 目标仍走定向输入校验，不使用前台全局命中作为统一前提；查询不适用或失败不得伪装成无覆盖。Space 明确不相交不拦截；相关重叠窗口层级不可证明时返回独立的不可验证错误。离屏目标不依赖 above 空列表：枚举屏上候选，仅有同 App、可见且覆盖落点的候选才查询 Space；不同 Space 通过，同 Space 层级未知明确拒绝。保留既有不将离屏兄弟当作屏上遮挡的范围，不扩大为所有后台窗口必须取得 Space。
4. **保持动作边界**。目标身份或几何变化仍拒绝；查询间发生变化时重新观察，不自动点击或换 global。继续保留普通 auto、sky_click、app_post 及单次 HID 的分离；不增加腾讯会议白名单，不因窗口标题或 AX focused 就跳过身份/遮挡保护，不默认 Raise。只有证据确认排序问题才按排序修复；如果窗口确实被覆盖，则修窗口绑定/观察选择或保持拒绝，不强行放行。
5. **补齐回归和复审**。核对取得层级的系统调用及其消费者，确保测试覆盖真实数据来源而非仅给纯函数传入已排序数组。后台 scroll、drag 和 app_post 与 click 共用校验，需要验证每个落点及 AX 查询前后各自取得新证据；禁止跨这两个阶段或跨激活阶段缓存。单次判定只查询一次层级，不引入固定轮询、额外截图或跨动作缓存。

## 自动测试矩阵

- all 集合乱序但有效 above 集合为空：不误报父窗口遮挡；all 集合目标在前而 above 集合确有子弹窗：仍拒绝。
- 真正的同 App/同 Space 上层接收窗口阻挡；后方、不可见、透明或不同 Space 窗口不误拦截。
- 其他 App 覆盖、屏外窗口与其他 Space 的普通定向输入仍保持支持；不要求切到前台。
- API 返回 nil、目标缺失、窗口销毁/ID 复用、几何变化、相关重叠候选的 Space 未知及两次采样矛盾均返回准确错误，无输入投递或自动 HID 回退。
- 新判定不改变前台 HID 的真实接收窗口检查、资格消费或 unknown/no-replay 规则。
- 查询依赖注入测试核对相对 window ID、选项及调用数量，避免只测试理想排序。

## 真实验收与交付

设备端先验证预约入口、主题、日期、时间选择，逐步观察实际效果并取消；对比目标处于前台、后台且被其他 App 覆盖两种状态。确认普通操作的 route、真实指针和前台 PID，不能把应用自行激活记为 global 输入。另用真实遮挡样本验证仍拒绝错误接收窗口。

完整提交验收需明确测试会议参数；观察表单不等于创建成功。云端 Agent → lane → App 的策略选择与设备端工具测试分别记录。

复审通过后依次发布 fork、更新 Today pin/manifest、构建并替换测试 App，再做 lane 回归。发布不属于本次制定计划的动作；回退使用上一已发布依赖 pin，不通过删除所有遮挡检查恢复功能。

## 参考

- [Apple optionOnScreenAboveWindow](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optiononscreenabovewindow)
- [Apple optionOnScreenOnly](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optiononscreenonly)
- [Apple optionAll](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optionall)

## 本轮结论

实现与验证见 [history](../../histories/2026-10/20261011-1915-coordinate-window-order.md)。日历实测为独立窗口，普通主窗口截图可能漏掉它；observePopups 能单独读取。日期与时间可通过普通坐标定位分段输入，必须观察提交字段后的实际值。不得将主窗口无变化直接判断为点击无效果。
