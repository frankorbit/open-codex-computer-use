# 2026-10-28 菜单取消动作可见性

用户要求继续复测、对比 Codex 行为并针对根因修复；不放宽权限、取消、超时和未知效果停止规则，不重复已发送操作。

## 根因及边界

提醒事项原生菜单已打开，但观察的菜单未展示 Cancel。`meaningfulRawActions`将菜单类全部AXCancel过滤，使模型只能看到父编辑器Cancel。旧过滤源于上游，并非当前系统授权时机。另一个弹层图片采集超时问题独立存在，本变更不调整它的预算。

## 实现

仅对AXMenu保留系统实际声明的AXCancel，继续隐藏AXPick/AXPress；MenuBar、MenuBarItem、MenuItem原过滤保持，Popover已有Cancel不变。没有声明动作就不生成Cancel。执行仍使用原先secondary-action入口、原对象与权限校验，无自动取消、目标替换或重试。

## 验证与review

新增3项测试先RED后GREEN，覆盖动作展示/缺失、既有菜单角色过滤、生产performSecondaryAction单次原对象投递、权限/超时类AX失败停止及无动作不投递。完整串行710项XCTest（8跳过）和68项Swift Testing通过。生产修改仅6行；无点击机制、截图、接口、定时参数或其他平台改动。

已运行SwiftFormat/SwiftLint：大文件存在既有全文件问题；只对改动范围执行标准格式化，新增行无SwiftLint问题，diff-check通过。此回归使用注入原生边界，不冒充真机验收。新签名App和菜单实际取消仍待验证。
