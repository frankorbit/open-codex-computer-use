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
              snapshot.windowElement != nil
        else {
            HoverPopupDiagnostics.record(.snapshotRootMissing)
            return .incomplete
        }
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
        let windowCapture = HoverPopupWindowCapture()
        return capture(dependencies: .init(
            readWindows: {
                guard !application.isTerminated, !application.isHidden else {
                    HoverPopupDiagnostics.record(.applicationUnavailable)
                    return nil
                }
                guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                    as? [[String: Any]] else { return nil }
                return info.compactMap(Observation.windowInfo)
            },
            readAX: { readAXState() },
            captureImage: { window in
                guard !budget.expired, let captured = try captureImage(window, windowCapture: windowCapture),
                      !budget.expired,
                      let data = encodeScreenshot(for: captured.image, config: settings.config).data
                else {
                    HoverPopupDiagnostics.record(.imageUnavailable)
                    return nil
                }
                return Observation.CapturedImage(data: data, captureBounds: captured.bounds)
            }
        ))
    }

    struct Dependencies {
        var readWindows: () -> [Observation.Window]?
        var readAX: () -> Observation.State?
        var captureImage: (Observation.Window) throws -> Observation.CapturedImage?
    }

    func capture(
        dependencies: Dependencies,
        report: @escaping (HoverPopupDiagnostics.Reason) -> Void = HoverPopupDiagnostics.record
    ) -> HoverPopupCaptureResult {
        func unavailable(_ reason: HoverPopupDiagnostics.Reason) -> Observation.State? {
            report(reason)
            return nil
        }
        let result = Observation.captureResult(
            rootWindowID: rootID, pid: pid, rootBounds: rootBounds,
            requireForeground: false, allowInput: settings.allowInput,
            allowBackgroundInput: settings.allowBackgroundInput,
            dependencies: .init(readState: {
                guard !budget.expired else { return unavailable(.deadlineExpired) }
                guard let windows = dependencies.readWindows() else { return unavailable(.windowListUnavailable) }
                guard let index = windows.firstIndex(where: { $0.windowID == rootID }),
                      windows[index].isVisible else { return unavailable(.rootNotOnScreen) }
                guard windows[index].pid == pid, windows[index].bounds == rootBounds else {
                    return unavailable(.rootGeometryChanged)
                }
                // 先用 CG 作宽松候选筛选；无候选不进入 AX，也不把其他 App 纳入候选。
                let hasCandidate = windows[..<index].contains {
                    $0.pid == pid && $0.isVisible && $0.layer >= 0
                        && Observation.geometricallyRelated($0.bounds, rootBounds)
                }
                guard hasCandidate else { return Observation.State(windows: windows, rootIsForeground: false) }
                guard !budget.expired else { return unavailable(.deadlineExpired) }
                guard var state = dependencies.readAX() else { return unavailable(.axStateUnavailable) }
                guard !budget.expired else { return unavailable(.deadlineExpired) }
                guard let freshWindows = dependencies.readWindows() else { return unavailable(.windowListUnavailable) }
                state = Observation.State(
                    windows: freshWindows, independentWindowIDs: state.independentWindowIDs,
                    independentWindowBounds: state.independentWindowBounds, rootIsForeground: state.rootIsForeground
                )
                return state
            }, captureImage: dependencies.captureImage), budget: budget
        )
        if result.isIncomplete { report(.incompleteCapture) }
        return result
    }

    private func readAXState() -> Observation.State? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = readAXWindows(app) else { return nil }
        var ids: Set<CGWindowID> = []
        var bounds: [CGRect] = []
        var root: AXUIElement?
        for window in windows {
            guard prepare(window) else { HoverPopupDiagnostics.record(.axTimeoutSetup); return nil }
            let id = SkyLightSPI.shared.windowID(for: window)
            if id == rootID {
                let observedBounds = frame(window)
                guard observedBounds == rootBounds else {
                    HoverPopupDiagnostics.recordRootFrame(expected: rootBounds, observed: observedBounds)
                    return nil
                }
                root = window
                continue
            }
            guard let exclusion = windowExclusion(window, id: id) else {
                HoverPopupDiagnostics.record(.axExclusionUnavailable)
                return nil
            }
            if let id = exclusion.id { ids.insert(id) }
            if let rectangle = exclusion.bounds { bounds.append(rectangle) }
        }
        // 部分 App 的 AXWindows 不完整；只接受仍映射到绑定 ID 的 main/focused 句柄。
        guard let root = validatedRoot(root, app: app) else { return nil }
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

    private func readAXWindows(_ app: AXUIElement) -> [AXUIElement]? {
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
            HoverPopupDiagnostics.record(.axWindowsUnavailable)
            return nil
        }
        guard windows.count <= Self.maximumAXWindows else {
            HoverPopupDiagnostics.record(.axWindowLimit)
            return nil
        }
        return windows
    }

    private func validatedRoot(_ root: AXUIElement?, app: AXUIElement) -> AXUIElement? {
        guard let root = root ?? boundRoot(app) else { HoverPopupDiagnostics.record(.axRootMissing); return nil }
        guard rootOwnerMatches(root) else { HoverPopupDiagnostics.record(.axRootOwnerMismatch); return nil }
        let observedBounds = frame(root)
        guard observedBounds == rootBounds else {
            HoverPopupDiagnostics.recordRootFrame(expected: rootBounds, observed: observedBounds)
            return nil
        }
        guard !application.isTerminated, !application.isHidden else {
            HoverPopupDiagnostics.record(.applicationUnavailable)
            return nil
        }
        guard !budget.expired else { HoverPopupDiagnostics.record(.deadlineExpired); return nil }
        return root
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

    private func captureImage(
        _ window: Observation.Window, windowCapture: HoverPopupWindowCapture
    ) throws -> (image: CGImage, bounds: CGRect?)? {
        guard !budget.expired else { return nil }
        do {
            let budget = budget, rootID = rootID
            if let image = try BlockingAsyncBridge.run({
                try await windowCapture.capture(window, rootID: rootID, budget: budget)
            }) {
                return (image, window.bounds)
            }
        } catch {
            // 显示器裁剪失败时仍可退回硬件缓冲区；预算耗尽时才上报，由调用方标记观察不完整。
            guard !budget.expired else { throw error }
        }
        guard !budget.expired else { return nil }
        // 退回：硬件缓冲区只含该窗口（材质无底色）；已校验图片与完整窗口等比，正好覆盖 window.bounds。
        guard let image = PopupWindowImage.hardware(window.windowID, bounds: window.bounds) else { return nil }
        return (image, window.bounds)
    }
}
