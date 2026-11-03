# 选中状态证据修复

用户要求继续修复选中状态判断不准确，并对照 Codex 的 Computer Use 输出。

## 改动

- 新增 AXSelectionObservation：有界采样选择容器的 AXSelectedChildren，只对当前遍历中的相同元素身份补正向证据。
- TargetedSelectionState 合并自身布尔值与父成员关系；明确 false 与正向成员冲突时输出 selection_conflict，缺失保持未知。
- AccessibilitySnapshot 完整树与 targeted query 均接入证据；完整树新增 Selected 汇总和未知/冲突说明，摘要不重新遍历或生成可操作索引。
- 添加 AXSelectionObservationTests，覆盖输出与 query 序列化、冲突、采样边界、截图独占、输入错误不吞掉或重放。

## Review 边界

没有改点击、键盘、保存、重试、权限停止、cloud 或 Web pin。没有根据 statusBar 文本猜测是哪一行被选中；该文本仅保留为独立观察。Codex 内部如何采集父成员未公开，本次对齐其对外可见语义。

## 验证

- 最终 XCTest：754 项，8 项跳过，0 失败；其中新增选择状态回归 10 项。
- Swift Testing：显式 `--no-parallel --disable-xctest --enable-swift-testing` 运行 77 项全部通过；预览套件单独运行 11 项全部通过。
- 默认完整运行仍有计时不稳定：最后一次 `LivePreviewKeyboardTests` 的 transient grace 用例出现 3 个断言失败；前一次还出现 quiet focus release 断言失败。未修改等待值、计时实现或测试断言。干净 HEAD d5f8b9 在独立 worktree 的完整测试通过（744 项 XCTest，8 项跳过；77 项 Swift Testing），所以不能仅凭源码未改这些文件就断言与本修复完全无关，也不将默认完整测试标为全绿。
- 验证日志：`tcu-selection-full-final-20261103.log`、`tcu-selection-preview-recheck-20261103.log`、`tcu-selection-swift-testing-serial-20261103.log`、`tcu-selection-baseline-full-20261103.log`。这些是本机临时证据，不提交日志。
- 新增/修改小文件 SwiftFormat 与 SwiftLint 通过；大型 AccessibilitySnapshot 的历史 lint 诊断数量保持不变（96），未进行无关的全文件重格式化。`git diff --check` 通过，仓库没有 justfile。

源码修复不等于当前签名 App 已更新；当前 App/pin 仍为 d5f8b9，本轮不提交或推送。观察结果可确认选中，但不能清除已发送输入的错误或自动重放；Finder setter 的 -25205 本身未修复。后续仍需新签名 App 实机验收及预览并发计时失败的独立定位。
