# 键盘接收者 AX 超时隔离

用户要求继续处理第8题 Numbers 冷启动验收阻塞。本轮未重新操作 Numbers 草稿。

## 证据与判断

- 对照正在运行的 native 版本，Return 自动路径在后台 key-window 准备后调用 KeyboardReceiver.read(requireEditable:false)。该分支只查询 AXFocusedWindow；日志中的 -25204 因而可定位至这一查询。失败发生在 keyboard_submission 之前。
- TargetedAX.resolveTargetWindow 把 system-wide AX 对象超时设为 0.1 秒；Apple SDK 的 AXUIElementSetMessagingTimeout 说明该设置改变进程全局默认值。新创建的键盘接收者对象未显式设置自己的超时，存在观察短预算污染输入校验的确定性问题。
- -25204 也可能由其他消息失败引起。旧日志没有属性耗时，不能把这次真实失败唯一归因于 100ms；新版 Numbers 真机验收仍待进行。

## 改动

- 新增 KeyboardReceiverAXReader：严格接收者读取显式使用已有 axInputMessagingTimeout（2 秒）作为整轮共享预算，每个 AX 请求仅使用剩余时间，完成后将当前对象恢复为默认继承值。既不修改 system-wide 设置，也不增加读取重试。
- 校验前后检查取消和截止时间；超时设置/恢复失败也停止。保留窗口身份、输入所属进程及可编辑性要求，不能读取的窗口绝不当作匹配。
- 增加属性名、操作类型、AX 结果码、预算和耗时诊断，不写属性值、输入内容或文稿名。保持既有错误停止与未知结果包装，未改变输入允许状态或重放策略。
- 仅严格 read 路径受影响：auto press_key/type_text 和上一轮 Finder 文本粘贴校验。显式 sky_key、普通应用 paste、鼠标、滚动、截图、菜单路由和焦点准备时序均未调整。
- 上一轮 Finder paste 的未提交改动完整保留，不把它记为已发布。

## 回归与 review

- 新增 10 项测试：8 项 reader 边界、1 项 MCP→Service→接收者读取/焦点清理入口（7种场景）、1 项诊断隐私。
- 入口覆盖 150ms 响应在旧 100ms 下失败但新预算内通过、真实权限失败、无法完成、窗口变化、取消、超时、投递后未知；失败前零投递，投递后最多一次，无兜底，清理恰好一次。
- XCTest 全量：773项、8跳过、0失败。Swift Testing 默认并发运行有3个预览计时测试失败；显式串行77项通过。默认并发并非全绿，没有修改预览测试阈值；未做干净 HEAD 对照，不能断言全部失败均为基线。
- Node REPL 全套51项通过，包含未知结果不自动回退/重放。SwiftLint 对本轮接收者源码与测试无警告，SwiftFormat、文档骨架及 diff check 通过。仓库无 justfile。
- 取舍：慢接收者查询的等待可能从继承的100ms延长至最多2秒；整轮共享预算，非逐属性累加。同步 AX 请求只能返回后检查取消。不存在额外固定等待。
- 本轮未提交、推送、更新 Web pin、部署或编译签名 App；自动化回归不等于 Numbers 真机整题通过。
