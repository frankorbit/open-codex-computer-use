# 弹层后台定向接收者校验

## 请求与根因

继续排查 Numbers 位置弹层输入被拒绝，要求对照 Codex、修复并回归，不重放操作或放宽权限/停止规则。

历史调用确实在发送前被 exact receiver 门控拒绝，日志未记录实际 receiver ID，因此不声称已定位某个遮挡窗口。代码把 sky_click 定向窗口输入也交给桌面最上层鼠标命中检查，与普通后台坐标点击契约不一致。另一个已验证差异是 Codex AXWindow 可见文件 URL，本实现只展示 Web URL，导致路径核验额外打开位置弹层。

## 改动

- global 保留精确鼠标命中；sky_click 校验凭证绑定的接收窗口及同应用上层窗口/Space 遮挡。
- 保留 root/popup 身份、几何、可见顺序、有效期、单次 token、move 后复验及无自动重放。
- 增加白名单接收者诊断；不记录路径或输入内容。
- AXWindow 展示 AXDocument，缺失不猜测；AXWebArea 及其他角色行为保持。

## 验证与边界

- 631 项 XCTest（8 项环境相关跳过）、68 项 Swift Testing 首轮全量通过；后续测试拆分与新增前置拒绝场景再次验证。
- 新测试覆盖其他 App 遮挡、同 App 遮挡、未知 Space、几何/身份改变、等待后复验、投递前与 move 后拒绝、单次投递与 token 消耗。
- Codex 对照可读文件 URL，但标题元素点击报告 elementHasNoFrame，未重放；不能声称该路径的 Codex 点击已成功。
- 新签名 App 的实际弹层与原文件持久化验收仍待执行，不能用测试通过替代。
