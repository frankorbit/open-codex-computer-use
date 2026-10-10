# 恢复设备端本地画中画

## 诉求与实现

恢复重构前的画中画，在 Today 设备 helper 中由 `OPEN_COMPUTER_USE_LIVE_PREVIEW=1` 启用，上游默认不开启。

- 从实际 OCU 快照发布 PID / windowID，使用 ScreenCaptureKit 单窗口流，20 fps 目标帧率、最长边 960 像素、仅保留最新帧。
- 本地非激活浮窗，连续帧不进入工具结果、Node 或模型，不建立输入引用。预览内容不是任务完成证据。
- 与软件光标共用绘制器和运动状态；Today 主题见同日光标配色记录。
- 切窗、尺寸改变、收起及停止均换代，拒绝迟到帧。重新显示时按同一窗口身份刷新几何；保留运行进程对象以拒绝退出后 PID 复用。
- 收起只停预览；宿主可发 `ai.today.ocu.show-preview`，object 为 `OPEN_COMPUTER_USE_PREVIEW_SESSION`，恢复对应 run 的预览。
- 系统共享停止时发送同一 session 的 `ai.today.ocu.stop-run`，宿主走已有停止流程。EOF / MCP 会话结束清理；进程退出由系统释放窗口和捕获资源。
- 工具输入期间预览窗口穿透鼠标，避免成为前台点击接收者；不放宽目标窗口校验。

## 验证与边界

纯状态回归覆盖 opt-in、窗口身份、几何、迟到帧、隐藏、恢复、reset 和跨屏光标坐标；配色有独立像素回归。完整非 live 测试通过。

受控两个临时 NSPanel 验证了 `ignoresMouseEvents=true` 后 `NSWindow.windowNumber(at:)` 返回底层窗口；未向用户应用发送输入。

仅镜像 OCU 当前绑定窗口，独立菜单或弹窗随后续 OCU 观察切换；不捕获整屏或所有同 PID 窗口。实际 Chat 任务、多屏视频显示及用户视觉验收另行记录，不以编译/单元测试代替。

## 比例回归修正

用户发现宽窗口在预览中出现明显上下黑边。对照旧版 `ComputerUseActionPreviewView.showFrame`，新版只设置 `contentAspectRatio`，遗漏了按图像比例调用 `setContentSize`；约束本身不会重设初始 360×240 的容器。

恢复首帧和图像尺寸变化时同步内容高度的行为，沿用旧版自动适配时 240–640 点宽度范围。连续同尺寸帧只刷新图像，不反复设置比例或改变用户手动缩放后的尺寸，保持完整图像，不拉伸、不裁切。

新增使用真实 AppKit 面板但不展示窗口的回归，验证宽画面、手动调整后连续帧、横竖切换和清空后的新首帧；允许系统窗口尺寸取整误差。六项预览测试通过，SwiftLint / SwiftFormat 验证通过。此项为 fork 源码修正，尚未更新 Today 的固定依赖版本或重新打包运行中的 App；鼠标穿透期间的交互限制是另一个问题，此次未调整。
