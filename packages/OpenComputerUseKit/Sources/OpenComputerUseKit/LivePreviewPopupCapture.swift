import AppKit
import ApplicationServices
import CoreImage
import ScreenCaptureKit

/// AX 与单窗截图仅在独立 actor 中限频执行，绝不从实时帧回调同步读取。
actor LivePreviewPopupCapture {
    typealias Window = LivePreviewPopup.Window
    typealias State = LivePreviewPopup.State

    struct Dependencies {
        var readState: () -> State?
        var readWindows: () -> [Window]?
        var capture: (Window) async throws -> CGImage?
    }

    private var busy = false
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    func refresh(target: LivePreviewTarget, expected: [Window]) async -> [LivePreviewPopup.Layer] {
        // 取消无法中断系统截图调用；跨 generation 仍保持最多一个采集任务。
        guard !busy, !Task.isCancelled else { return [] }
        busy = true
        defer { busy = false }
        var content: SCShareableContent?
        return await Self.collect(target: target, expected: expected, dependencies: Dependencies(
            readState: { Self.readState(target) },
            readWindows: { Self.windows(pid: target.pid) },
            capture: { window in
                if content == nil {
                    content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                }
                guard let content else { return nil }
                return try await Self.capture(window, content: content)
            }
        ))
    }

    static func collect(
        target: LivePreviewTarget, expected: [Window], dependencies: Dependencies
    ) async -> [LivePreviewPopup.Layer] {
        let deadline = ProcessInfo.processInfo.systemUptime + LivePreviewPopup.lifetime
        func validState() -> State? {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  let state = dependencies.readState(), state.windows == expected else { return nil }
            return state
        }
        guard let before = validState() else { return [] }
        let candidates = Array(LivePreviewPopup.candidates(target: target, state: before)
            .prefix(LivePreviewPopup.maximumCount))
        var layers: [LivePreviewPopup.Layer] = []
        for window in candidates {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  dependencies.readWindows() == expected else { return [] }
            do {
                if let image = try await dependencies.capture(window), LivePreviewPopup.hasVisibleContent(image) {
                    let canvas = LivePreviewPopup.canvas(root: target.bounds, layers: layers)
                    if LivePreviewPopup.boundedCanvas(canvas.union(window.bounds), root: target.bounds) {
                        layers.append(.init(window: window, image: image))
                    }
                }
            } catch {
                InputDiagnostics.event("live_preview_popup_capture_failed")
            }
        }
        // 再读 AX，标准窗口身份变化也必须撤销；不复用 service 的观察结果或输入授权。
        guard let after = validState() else { return [] }
        let current = LivePreviewPopup.candidates(target: target, state: after)
        return layers.filter { current.contains($0.window) }
    }

    nonisolated static func windows(pid: pid_t) -> [Window]? {
        guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap(HoverPopupObservation.windowInfo).filter { $0.pid == pid }
    }

    private static func readState(_ target: LivePreviewTarget) -> State? {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated, !app.isHidden else {
            return nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        guard let axWindows = axWindows(pid: target.pid) else { return nil }
        var metadata: [AXWindow] = []
        for window in axWindows {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  AXUIElementSetMessagingTimeout(window, 0.05) == .success else { return nil }
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == target.pid else { return nil }
            let id = SkyLightSPI.shared.windowID(for: window)
            if id == target.windowID {
                metadata.append(AXWindow(windowID: id, bounds: frame(window), isStandard: false))
                continue
            }
            guard let standard = isStandardWindow(window) else { return nil }
            metadata.append(AXWindow(windowID: id, bounds: standard && id == nil ? frame(window) : nil,
                                     isStandard: standard))
        }
        guard !app.isTerminated, !app.isHidden, let windows = windows(pid: target.pid) else { return nil }
        return classifiedState(target: target, windows: windows, axWindows: metadata)
    }

    private static func axWindows(pid: pid_t) -> [AXUIElement]? {
        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], windows.count <= 32 else { return nil }
        return windows
    }

    struct AXWindow {
        let windowID: CGWindowID?
        let bounds: CGRect?
        let isStandard: Bool
    }

    static func classifiedState(target: LivePreviewTarget, windows: [Window], axWindows: [AXWindow]?) -> State? {
        guard let axWindows else { return nil }
        var ids: Set<CGWindowID> = []
        var bounds: [CGRect] = []
        for window in axWindows {
            if window.windowID == target.windowID {
                if let observed = window.bounds, observed != target.bounds { return nil }
                continue
            }
            guard window.isStandard else { continue }
            if let id = window.windowID {
                ids.insert(id)
            } else if let frame = window.bounds {
                bounds.append(frame)
            } else {
                return nil
            }
        }
        // Qt/WPS 的 AXWindows 可能没有 root；绑定 PID/ID 与实时 CG 几何仍为权威。
        // AX 通信失败和无法排除的标准窗口继续拒绝弹层，缺少 root AX 本身不应拒绝。
        return State(windows: windows, independentWindowIDs: ids, independentWindowBounds: bounds)
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool? {
        var subrole: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        guard result == .success || result == .attributeUnsupported || result == .noValue else { return nil }
        guard result != .success || subrole is String else { return nil }
        return HoverPopupObservation.excludesAXWindow(subrole: subrole as? String)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return LivePreviewTarget(pid: 1, windowID: 1, bounds: CGRect(origin: point, size: dimensions))?.bounds
    }

    private static func capture(_ window: Window, content: SCShareableContent) async throws -> CGImage? {
        guard !Task.isCancelled, let target = content.windows.first(where: {
            $0.windowID == window.windowID && $0.owningApplication?.processID == window.pid
                && $0.frame == window.bounds && $0.isOnScreen
        }) else { return nil }
        let configuration = LivePreviewCapture.configuration(for: window.bounds.size, transparent: true)
        let filter: SCContentFilter
        let independent: Bool
        if #available(macOS 14.2, *),
           let region = LivePreviewPopupRegion.displayRegion(window: window.bounds,
                                                             displays: content.displays.map(\.frame)) {
            // 只包含精确 window ID；用显示器本地裁剪避免系统把父窗和 sheet 分组后缩放进弹层。
            // display-bound 过滤器默认包含子窗，必须显式关闭，关联弹层由各自采集负责。
            filter = SCContentFilter(display: content.displays[region.index], including: [target])
            configuration.sourceRect = region.sourceRect
            configuration.includeChildWindows = false
            configuration.ignoreShadowsDisplay = true
            independent = false
        } else {
            // 跨屏或部分离屏不猜裁剪偏移；独立窗口只有完整区域契约成立时才允许合成。
            filter = SCContentFilter(desktopIndependentWindow: target)
            guard LivePreviewPopupRegion.matchesIndependentContent(filter.contentRect, window: window.bounds)
            else { return nil }
            independent = true
        }
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter,
                                                                       configuration: configuration)
        guard sample.isValid, let buffer = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
              as? [[SCStreamFrameInfo: Any]], let info = attachments.first,
              info[.status] as? Int == SCFrameStatus.complete.rawValue,
              !independent || LivePreviewPopupRegion.matchesCapturedFrame(info[.screenRect], window: window.bounds),
              let image = imageContext.createCGImage(
                  CIImage(cvPixelBuffer: buffer),
                  from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
              ) else { return nil }
        guard image.width == configuration.width, image.height == configuration.height else { return nil }
        return image
    }
}
