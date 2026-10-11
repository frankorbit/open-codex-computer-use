# 后台输入链路对齐

## 目标与边界

复用上游 sky_click / sky_key，统一元素与坐标鼠标兜底、消除旧焦点输入、补树裁剪后的焦点摘要。Today 默认后台，显式前台兼容单独授权。不复制闭源 Codex 实现；不新增 paste/selectText 或修复全部浮层坐标。

## 风险与验证

保留窗口身份检查和未知输入不重放。回归覆盖自动路由、实时接收者改变、无焦点、输入未知结果和树裁剪。运行 Swift 测试、Node 回归、Today 检查及集成编译。真实飞书和腾讯会议验收与自动化检查分开报告。

## 进度

- [x] 核对上游与 Codex 多案例观察边界。
- [x] 核心后台路由与实时焦点实现。
- [x] 本地 override 集成检查与独立复审。
- [x] 记录验证结果及未对齐项。
- [ ] 获得提交授权后发布 fork revision、同步 Today pin 并验证干净构建。

## 自动化验证记录

- fork 全量 Swift XCTest：335 项，7 项需显式启用的 live 测试跳过，0 失败；额外 Swift Testing 12 项通过。
- fork Node REPL：40 项通过；最后工具文案/开关契约回归 8 项通过；swift build 通过。
- 新焦点实现 SwiftFormat / SwiftLint 通过；文档检查通过。fork check-repo 因 HEAD 原本缺失模板文件而失败，未扩大范围补模板。
- TodayOCU 使用本地 fork override 编译通过；Node 49 项、cloud 6 文件 183 项通过；native just check 为 0 violations。TodayOCU Swift Testing 39 项、依赖相关 Swift Testing 29 项通过；临时 override 已清理，未留下 Packages 目录。

## 对齐边界

| 项目 | 状态 |
| --- | --- |
| 上游 sky_click / sky_key 原语 | 复用现有实现，补默认选路与接收者校验 |
| Codex 样本中的后台点击与输入策略 | 行为目标一致；未取得官方闭源内部实现 |
| 默认真实鼠标/前台干扰 | 默认鼠标路线取消 global；App 自身行为与目标兼容性仍需实测 |
| 颜色浮层、时间下拉、完整预约 | 不在本次自动化验证通过声明内 |
| paste / selectText | 当前 OCU JS 未新增；不声称工具面完全相同 |
| 工程交付 | 未提交、未推送、未部署，依赖 pin 仍为旧版本；本地 override 不等于正式集成 |

## 最终复审

两轮独立静态复审后，本轮 fork 逻辑无新增明确 P1/P2。唯一 P2 交付阻断为 Today 仍固定旧 revision：新前台点击授权与键盘逻辑尚未进入可复现的干净构建。环境白名单已确认保留新开关，不是漏传。正式集成必须在用户明确授权提交之后，按 fork 提交/推送、native pin+manifest 同步、干净构建顺序收尾；目前不宣称 App 已修复或已与 Codex 全面对齐。
