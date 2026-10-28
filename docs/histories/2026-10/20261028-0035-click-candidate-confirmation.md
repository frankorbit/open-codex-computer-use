# 侧栏点击误用子文本框确认动作

用户要求继续复测，发现失败先诊断并修复，不放宽停止规则、不重放已发送操作。

## 根因证据

提醒事项侧栏行的一次点击被后代扫描转换成 AXTextField 的 AXConfirm。AX 返回 success，但列表选择不变。新输入诊断明确记录原始目标、descendant、confirm、AXTextField 与返回码；不是根据“没有变化”猜测坐标失败。

## 修复边界

左键单击的非原始 AXTextField 候选不再通过 AXConfirm 消费父目标点击。用 AX 对象身份判断是否原目标，不依赖日志来源或元素索引。其他角色、直接原目标、AXPress/AXOpen、显式secondary、右键/双击、Web专用行路径和已有鼠标校验保持原行为。

只在输入发送前排除不符合点击意图的候选；合法动作发送后的成功/错误仍立即返回或抛出，不再尝试其他候选或鼠标。没有重试机制。

## 验证

新增11项完整click入口回归通过，完整串行691 XCTest（8跳过）及68 Swift Testing通过，Web Runtime269项通过。SwiftFormat与SwiftLint新测试通过，Service改动行零新增lint问题。此前Edit Details未打开尚未有同样的动作证据，不能声称本修复已覆盖该问题。原失败侧栏不重放，新版本使用独立未发送目标验收。
