# 后台坐标窗口层级校验

## 诉求与范围

按复审后的计划修复窗口排序证据，保留已有后台、显式单次前台和输入不确定性边界；通过真实腾讯会议表单进行可取消验收。本轮未提交、推送或部署。

## 实现

- `CoordinateWindowQuery.swift`：屏上目标使用 above + includingWindow，查询失败与空候选分开；返回结果重验目标身份、几何和可见性。
- 离屏目标不把 above 空数组视为证据，改查屏上候选并单独重验目标。没有相关候选不要求 Space；不同 Space 放行；同 Space 重叠但层级未知明确拒绝。未添加私有窗口排序 SPI。
- `CoordinateWindow.swift`：身份检查、前台实际接收窗口检查、后台遮挡检查保持分离；后台证据惰性获取。不缓存跨 AX 前后检查或激活阶段的证据。
- `ComputerUseService.swift`：只在共享后台坐标校验入口接入新证据。普通 auto/sky_click/app_post 路由、HID 单次能力、截图、模型、预览均未改动。
- `CoordinateWindowQueryTests.swift`：9 项新增测试覆盖真实查询选项、乱序 all、查询错误、目标漂移、模式隔离、条件式 Space、离屏行为以及单点/双点 app_post 在 AX 前后的重验。

## 验证与复审

- 90 项 XCTest + 6 项 Swift Testing 定向测试通过，包括 CoordinateWindow、CoordinateClick、ForegroundHover、HoverPopupClick、ExecutionPolicy、InputDiagnostics、SnapshotInvalidation。
- 当前 TodayOCUHelper 编译通过。SwiftPM 本地 edit 只用于编译，随后清理，正式 pin 仍为 8ba6ed8。
- 新增文件默认 SwiftLint 严格检查通过；4 个窗口相关改动文件 SwiftFormat 检查通过。旧窗口函数既有的参数数量告警没有通过修改全仓规则掩盖。
- Today `just check` 通过。初次误扫描 SwiftPM edit 的外部源码，清理后 Swift 检查正常；本机 Homebrew Node 缺少 llhttp 动态库，最终通过在 PATH 前置项目已有的 Node 执行原命令完成检查，未改系统安装。
- fork `make check-docs` 和 `git diff --check` 通过。
- 复审检查全部生产调用者：hover 激活前 identityOnly、HID 最终接收者、popup 接收者均不触发新后台查询；app_post 滚动/拖拽保留每落点及 AX 前后独立查询。未发现本轮新增阻断项。

## 真实 App 结果

使用 Today 当前 WorkerJavaScriptSession → 编译的新 TodayOCUHelper → 腾讯会议，后台策略保持 background/background；不是云端 Agent/lane 验收，也未替换当前运行 Today 主 App。

- 普通 Schedule 点击在一轮中没有打开表单；显式单次 HID 成功打开表单，之后日期和输入操作恢复普通后台链路。
- 日期按钮 auto 实际走 sky_click，真实指针起止相同。主窗口截图没有日历，但 observePopups 单独捕获日历窗口，桌面图确认日历存在。因此“主窗口图未变化＝点击无效果”不成立。
- 故意用主窗口落点指向日历覆盖区域，被同 App 上层日历准确拒绝，日志没有 input_attempt。没有为选择日期移除保护或把 popup 坐标强塞进主窗口。
- 日期 setValue 返回但未改值；重新观察后，普通坐标选择日期的日字段 + sky_key Up 成功改到 2026/10/12。时间小时、分钟通过普通坐标 + sky_key 改为 10:00，失焦后截图显示 Mon、10:00。主题 setValue 成功回读测试标题。
- 表单最终取消，主页回读 No meetings；没有提交会议。
- 最终构建另起 helper 后，对照前台为 Codex、腾讯会议被覆盖的状态：普通点击通过新校验并保持 sky_click，真实指针和前台 PID 不变，但入口没有打开。这只证明后台路径未被新增检查阻断，不代表该次点击效果成功。
- 随后显式单次 HID 在 activation 阶段失败（诊断 20AF8A7F-A97F-46AA-8505-FAEFE641D4D8），无 input_attempt、无 HID 投递；只发生 identityOnly 检查，尚未进入新后台查询。回读仍为首页。保留此独立激活可靠性问题，未重复该输入。

## 限制

旧版现场这次未稳定重现主窗口误判遮挡，旧日志也缺少同步层级证据；修复针对已确认的排序契约缺陷，不能据此宣布它是旧失败的唯一原因。离屏/跨 Space 分支已单测，未完成真实跨 Space 或多显示器验收。日历候选观察不授予 popup 输入；本轮未增加后台 popup 点击 API。真实表单完成不代表会议创建成功或云端模型已学会此路径。
