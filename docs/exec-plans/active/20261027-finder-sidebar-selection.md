# Finder 侧栏导航单击

## 问题证据

Finder 身份修复实机通过后，侧栏 Documents 单击返回 AXOpen -25205，但 Codex 只读确认已导航。输入日志只有一次 click，后续无输入。Codex 对另一个 Desktop 行独立单击成功。不能从后置状态把错误吞掉，也不能重发原操作。

## 范围

仅 Finder 的原生 sidebar outline 的原始行目标、左键单击，在 AXAction/后代探测之前验证并发送一次 AXSelectedRows。排除其他 App、普通 outline、网页、标签后代和独立控件、双击与右键。已发送失败继续抛出，能力未知或权限失败继续停止；不改变 AXList、坐标、SkyLight、超时或停止策略。

## 验证

- [x] 单次选择/发送前拒绝/发送后失败不回退/范围排除及完整 click 入口回归。
- [x] 完整串行 672 XCTest（8 skipped）+68 Swift Testing 通过；静态 review 权限分类和读取预算问题已修复，文档检查通过。
- [ ] fork push → Web pin → 签名 App → 独立未发送过的侧栏目标验收。

## 边界

AXOpen 具体落到哪个隐藏后代尚无精确日志，现有源码说明未选中 row 不渲染子节点但点击扫描后代。此次不修改 action 名称映射，不把成功 setter 等同导航成功。原 Documents 点击不重放；Codex 目录完整回读见 11 项，仅一个本周花销，无同名副本；Today 本轮未完成自己的目录回读。

新增预检限制每次AX读取为剩余预算与50ms中的较小值，恢复默认超时；权限拒绝优先保留。实际Finder侧栏以Description: sidebar呈现，因此精确接受identifier或description，不扩大到普通outline。新文件SwiftFormat/SwiftLint strict通过。
