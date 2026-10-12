import AppKit
import ApplicationServices
import ScreenCaptureKit

extension HoverPopupObservation {
    /// 在请求环境还有效时冻结所有配置；worker 只使用值，不读取后续请求的环境。
    struct CaptureSettings {
        let config: ImageCaptureConfig
        let allowInput: Bool
        let allowBackgroundInput: Bool

        init(config: ImageCaptureConfig, policy: ExecutionPolicy?, backgroundAvailable: Bool) {
            self.config = config
            allowInput = policy == .compatible
            allowBackgroundInput = policy == .background && backgroundAvailable
        }
    }

    static func capture(for snapshot: AppSnapshot, mode: HoverPopupObservationMode) -> HoverPopupCaptureResult {
        let started = ProcessInfo.processInfo.systemUptime
        guard let rootID = snapshot.targetWindowID, let bounds = snapshot.windowBounds,
              snapshot.windowElement != nil else { return .incomplete }
        let settings = CaptureSettings(
            config: .current, policy: try? ExecutionPolicy.current(),
            backgroundAvailable: SkyLightSPI.shared.capability.isAvailable
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let budget = HoverPopupBudget(duration: min(mode.duration, settings.config.captureTimeout) - elapsed)
        let collector = HoverPopupSystemCapture(
            pid: snapshot.app.pid, rootID: rootID, rootBounds: bounds,
            application: snapshot.app.runningApplication, budget: budget, settings: settings
        )
        return HoverPopupCaptureWorker.shared.capture(budget: budget) { collector.capture() }
    }
}

/// 只运行在隔离 worker；不调用主线程 sync、输入诊断或 service/cache。
struct HoverPopupSystemCapture {
    typealias Observation = HoverPopupObservation
    static let maximumAXWindows = 32
    static let axTimeout: TimeInterval = 0.025
    let pid: pid_t
    let rootID: CGWindowID
    let rootBounds: CGRect
    let application: NSRunningApplication
    let budget: HoverPopupBudget
    let settings: Observation.CaptureSettings

    func capture() -> HoverPopupCaptureResult {
        capture(dependencies: .init(
            readWindows: {
                guard !application.isTerminated, !application.isHidden,
                      let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                      as? [[String: Any]] else { return nil }
                return info.compactMap(Observation.windowInfo)
            },
            readAX: { readAXState() },
            captureImage: { window in
                guard !budget.expired, let image = try captureImage(window), !budget.expired else { return nil }
                return encodeScreenshot(for: image, config: settings.config).data
            }
        ))
    }

    struct Dependencies {
        var readWindows: () -> [Observation.Window]?
        var readAX: () -> Observation.State?
        var captureImage: (Observation.Window) throws -> Data?
    }

    func capture(dependencies: Dependencies) -> HoverPopupCaptureResult {
        Observation.captureResult(
            rootWindowID: rootID, pid: pid, rootBounds: rootBounds,
            requireForeground: false, allowInput: settings.allowInput,
            allowBackgroundInput: settings.allowBackgroundInput,
            dependencies: .init(readState: {
                guard !budget.expired, let windows = dependencies.readWindows(),
                      let index = windows.firstIndex(where: { $0.windowID == rootID }),
                      windows[index].pid == pid, windows[index].bounds == rootBounds,
                      windows[index].isVisible else { return nil }
                // 先用 CG 作宽松候选筛选；无候选不进入 AX，也不把其他 App 纳入候选。
                let hasCandidate = windows[..<index].contains {
                    $0.pid == pid && $0.isVisible && $0.layer >= 0
                        && Observation.geometricallyRelated($0.bounds, rootBounds)
                }
                guard hasCandidate else { return Observation.State(windows: windows, rootIsForeground: false) }
                guard !budget.expired, var state = dependencies.readAX(), !budget.expired,
                      let freshWindows = dependencies.readWindows() else { return nil }
                state = Observation.State(
                    windows: freshWindows, independentWindowIDs: state.independentWindowIDs,
                    independentWindowBounds: state.independentWindowBounds, rootIsForeground: state.rootIsForeground
                )
                return state
            }, captureImage: dependencies.captureImage), budget: budget
        )
    }

    private func readAXState() -> Observation.State? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
              windows.count <= Self.maximumAXWindows else { return nil }
        var ids: Set<CGWindowID> = []
        var bounds: [CGRect] = []
        var root: AXUIElement?
        for window in windows {
            guard prepare(window) else { return nil }
            let id = SkyLightSPI.shared.windowID(for: window)
            if id == rootID {
                guard frame(window) == rootBounds else { return nil }
                root = window
                continue
            }
            guard let exclusion = windowExclusion(window, id: id) else { return nil }
            if let id = exclusion.id { ids.insert(id) }
            if let rectangle = exclusion.bounds { bounds.append(rectangle) }
        }
        // 部分 App 的 AXWindows 不完整；只接受仍映射到绑定 ID 的 main/focused 句柄。
        guard let root = root ?? boundRoot(app), rootOwnerMatches(root), frame(root) == rootBounds,
              !application.isTerminated, !application.isHidden,
              !budget.expired else { return nil }
        // 后台授权不依赖前台窗口；兼容模式查询也受同一 AX/总预算约束。
        var foreground = false
        if settings.allowInput, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
           let focused = attribute(app, kAXFocusedWindowAttribute) {
            foreground = CFEqual(focused, root)
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        return Observation.State(
            windows: [], independentWindowIDs: ids, independentWindowBounds: bounds, rootIsForeground: foreground
        )
    }

    private func boundRoot(_ app: AXUIElement) -> AXUIElement? {
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let value = attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = unsafeDowncast(value, to: AXUIElement.self)
            guard prepare(window) else { return nil }
            if SkyLightSPI.shared.windowID(for: window) == rootID { return window }
        }
        return nil
    }

    private func rootOwnerMatches(_ root: AXUIElement) -> Bool {
        var owner: pid_t = 0
        return AXUIElementGetPid(root, &owner) == .success && owner == pid
    }

    private func windowExclusion(
        _ window: AXUIElement, id: CGWindowID?
    ) -> (id: CGWindowID?, bounds: CGRect?)? {
        guard prepare(window) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value)
        guard [AXError.success, .attributeUnsupported, .noValue].contains(error) else { return nil }
        guard Observation.excludesAXWindow(subrole: value as? String) else { return (nil, nil) }
        if let id { return (id, nil) }
        guard let rectangle = frame(window) else { return nil }
        return (nil, rectangle)
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        let remaining = budget.remaining
        // 仅设置本次 AXWindows 查询产生的句柄，不修改快照持有的 root 或全局 AX 超时。
        return remaining > 0 && AXUIElementSetMessagingTimeout(element, Float(min(Self.axTimeout, remaining))) ==
            .success
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              !budget.expired else { return nil }
        return value
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let rectangle = CGRect(origin: point, size: dimensions)
        return Observation.validBounds(rectangle) ? rectangle : nil
    }

    private func captureImage(_ window: Observation.Window) throws -> CGImage? {
        if let image = SkyLightSPI.shared.hardwareCaptureWindow(window.windowID) { return image }
        guard !budget.expired else { return nil }
        // 不让内部超时释放 single-flight 槽位：SCK 真正完成前 worker 仍占用槽位。
        // 调用方由外层总预算退出；晚到结果不发布，也不会再开始下一张截图。
        let budget = budget
        return try BlockingAsyncBridge.run {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !budget.expired,
                  let target = content.windows.first(where: {
                      $0.windowID == window.windowID && $0.owningApplication?.processID == window.pid
                          && $0.frame == window.bounds
                  }) else { return nil }
            let configuration = SCStreamConfiguration()
            guard let width = Int(exactly: ceil(window.bounds.width)),
                  let height = Int(exactly: ceil(window.bounds.height)) else { return nil }
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration
            )
        }
    }
}
