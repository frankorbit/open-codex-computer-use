import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

struct HoverPopupObservation {
    let token: String
    let windowID: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let imageData: Data
    let pixelSize: CGSize
    var permitsInput = true

    var content: [ToolResultContentItem] {
        content(policy: (try? ExecutionPolicy.current()) ?? .background)
    }

    func content(policy: ExecutionPolicy) -> [ToolResultContentItem] {
        let canClick = permitsInput && !policy.isBackground
        let identity = "Popup candidate: windowID=\(windowID), pid=\(pid)."
            + (canClick ? " popup_token=\"\(token)\"." : " Observation only; no input token.")
        let geometry = "bounds=(\(bounds.minX), \(bounds.minY), \(bounds.width), \(bounds.height)) screen points"
            + " (Quartz top-left, y down); pixelSize=(\(pixelSize.width), \(pixelSize.height))."
            + " Main coordinates unchanged."
        let usage: String
        if canClick {
            usage = "Image-local pixels: click({popup_token:\"\(token)\",x:...,y:...,click_method:\"global\"})"
                + " / JS app.click([x,y],{popupToken:\"\(token)\",clickMethod:\"global\"})."
                + " Candidate only, not parent proof; single-use token requires"
                + " live focus/identity/geometry/receiver checks."
        } else {
            usage = "Image coordinates are local to this observed window, not the main-window screenshot. "
                + "Same-process geometric candidate only, not proof of popup ownership. "
                + "This observation does not authorize popup input."
        }
        var image = ToolResultContentItem.screenshotImage(imageData).dictionary
        var metadata: [String: Any] = ["windowID": windowID, "pid": pid, "observationOnly": !canClick]
        if canClick { metadata["token"] = token }
        image["_meta"] = ["ocuPopup": metadata]
        return [.text([identity, geometry, usage].joined(separator: "\n")), ToolResultContentItem(dictionary: image)]
    }

    static let unavailableNote = "No verifiable popup candidates were captured. Observation is limited to "
        + "visible same-process windows near the bound window; inaccessible AX window metadata, hidden/off-screen "
        + "windows, changing identity/geometry or capture failure may omit candidates. This does not prove no popup exists."

    static func capture(for snapshot: AppSnapshot) -> [HoverPopupObservation] {
        guard let rootID = snapshot.targetWindowID, let bounds = snapshot.windowBounds,
              let root = snapshot.windowElement,
              !snapshot.app.runningApplication.isTerminated,
              !snapshot.app.runningApplication.isHidden else { return [] }
        let config = ImageCaptureConfig.current
        return capture(
            rootWindowID: rootID, pid: snapshot.app.pid, rootBounds: bounds,
            requireForeground: false, allowInput: (try? ExecutionPolicy.current()) == .compatible,
            dependencies: Dependencies(
                readState: { liveState(for: snapshot, root: root) },
                captureImage: { window in
                    guard let image = try captureImage(window, config: config) else { return nil }
                    return encodeScreenshot(for: image, config: config).data
                }
            )
        )
    }

    /// 测试入口只接受窗口元数据与内存图片，不需要运行 AX、截图或 GUI。
    struct Window: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        var alpha: Double = 1
        var isOnscreen = true
        var layer = 0

        var isVisible: Bool {
            windowID != 0 && pid > 0 && alpha.isFinite && alpha > 0 && isOnscreen
                && HoverPopupObservation.validBounds(bounds)
        }
    }

    struct State {
        // WindowServer 顺序由前到后；不能按 layer 或窗口编号重新排序。
        let windows: [Window]
        var independentWindowIDs: Set<CGWindowID> = []
        var independentWindowBounds: [CGRect] = []
        var rootIsForeground = true
    }

    struct Dependencies {
        var readState: () -> State?
        var captureImage: (Window) throws -> Data?
    }

    static func capture(
        rootWindowID: CGWindowID, pid: pid_t, rootBounds: CGRect,
        requireForeground: Bool = true, allowInput: Bool = true, dependencies: Dependencies
    ) -> [HoverPopupObservation] {
        var inputEligible = allowInput
        func readState() -> State? {
            let state = dependencies.readState()
            inputEligible = inputEligible && state?.rootIsForeground == true
            return state
        }
        func validRoot(_ state: State) -> Bool {
            guard (!requireForeground || state.rootIsForeground),
                  state.windows.count(where: { $0.windowID == rootWindowID }) == 1,
                  let root = state.windows.first(where: { $0.windowID == rootWindowID }) else { return false }
            return root.pid == pid && root.bounds == rootBounds && root.isVisible
        }
        func candidates(_ state: State) -> [Window] {
            guard validRoot(state),
                  let rootIndex = state.windows.firstIndex(where: { $0.windowID == rootWindowID }) else { return [] }
            return state.windows[..<rootIndex].filter { window in
                window.pid == pid && window.isVisible && window.layer >= 0
                    && state.windows.count(where: { $0.windowID == window.windowID }) == 1
                    && !state.independentWindowIDs.contains(window.windowID)
                    && !state.independentWindowBounds.contains(window.bounds)
                    && geometricallyRelated(window.bounds, rootBounds)
            }
        }
        guard let initial = readState(), validRoot(initial) else { return [] }
        var captured: [(Window, HoverPopupObservation)] = []
        // 同时限制截图尝试次数，避免大量临时窗口导致无界等待。
        for window in candidates(initial).prefix(4) {
            guard let before = readState(), validRoot(before) else { return [] }
            guard candidates(before).contains(window) else { continue }
            let data: Data?
            do {
                data = try dependencies.captureImage(window)
            } catch {
                InputDiagnostics.event("hover_popup_capture_failed")
                data = nil
            }
            // 截图失败也复核 root，不能在中途切窗后继续发出其他 token。
            guard let after = readState(), validRoot(after) else { return [] }
            guard candidates(after).contains(window), let data, let size = pixelSize(of: data) else { continue }
            captured.append((window, HoverPopupObservation(
                token: UUID().uuidString, windowID: window.windowID, pid: window.pid,
                bounds: window.bounds, imageData: data, pixelSize: size
            )))
        }
        // 后续截图期间，之前捕获的窗口也可能关闭或迁移。
        guard let final = readState(), validRoot(final) else { return [] }
        let current = candidates(final)
        return captured.filter { current.contains($0.0) }.map {
            var observation = $0.1
            observation.permitsInput = inputEligible
            return observation
        }
    }

    static func geometricallyRelated(_ popup: CGRect, _ root: CGRect) -> Bool {
        guard validBounds(popup), validBounds(root) else { return false }
        let overlapX = min(popup.maxX, root.maxX) - max(popup.minX, root.minX)
        let overlapY = min(popup.maxY, root.maxY) - max(popup.minY, root.minY)
        // 允许贴边及 16pt 的投影重叠间隙；角落相近不代表属于该 root。
        return (overlapX > 0 && overlapY >= -16) || (overlapY > 0 && overlapX >= -16)
    }

    private static func validBounds(_ bounds: CGRect) -> Bool {
        [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height, bounds.maxX, bounds.maxY]
            .allSatisfy(\.isFinite) && bounds.size.width > 0 && bounds.size.height > 0
    }

    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    private static func liveState(for snapshot: AppSnapshot, root: AXUIElement) -> State? {
        guard rootMatchesSnapshot(snapshot, root: root) else { return nil }
        let foregroundBefore = InputSimulation.isForegroundWindow(snapshot.app, window: root)
        guard let exclusions = independentWindows(pid: snapshot.app.pid, root: root),
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // AX 查询可能阻塞，结束时复验目标身份；前台状态只决定能否发放输入凭证。
        guard rootMatchesSnapshot(snapshot, root: root) else { return nil }
        return State(
            windows: info.compactMap(windowInfo),
            independentWindowIDs: exclusions.ids, independentWindowBounds: exclusions.bounds,
            rootIsForeground: foregroundBefore && InputSimulation.isForegroundWindow(snapshot.app, window: root)
        )
    }

    private static func rootMatchesSnapshot(_ snapshot: AppSnapshot, root: AXUIElement) -> Bool {
        var owner: pid_t = 0
        return !snapshot.app.runningApplication.isTerminated && !snapshot.app.runningApplication.isHidden
            && AXUIElementGetPid(root, &owner) == .success && owner == snapshot.app.pid
            && snapshot.targetWindowID != nil && SkyLightSPI.shared.windowID(for: root) == snapshot.targetWindowID
            && snapshot.windowBounds != nil && axFrame(root) == snapshot.windowBounds
    }

    static func windowInfo(_ info: [String: Any]) -> Window? {
        func number(_ key: CFString) -> Double? {
            guard let value = info[key as String] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        guard let idValue = number(kCGWindowNumber), let windowID = CGWindowID(exactly: idValue), windowID != 0,
              let pidValue = number(kCGWindowOwnerPID), let pid = pid_t(exactly: pidValue), pid > 0,
              let alpha = number(kCGWindowAlpha), let layerValue = number(kCGWindowLayer),
              let layer = Int(exactly: layerValue),
              let visible = info[kCGWindowIsOnscreen as String] as? NSNumber,
              CFGetTypeID(visible) == CFBooleanGetTypeID(),
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary), validBounds(bounds) else { return nil }
        return Window(
            windowID: windowID,
            pid: pid,
            bounds: bounds,
            alpha: alpha,
            isOnscreen: visible.boolValue,
            layer: layer
        )
    }

    private static func independentWindows(pid: pid_t, root: AXUIElement) -> (ids: Set<CGWindowID>, bounds: [CGRect])? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXWindowsAttribute as CFString,
            &value
        ) ==
            .success,
            let windows = value as? [AXUIElement] else { return nil }
        var ids: Set<CGWindowID> = []
        var bounds: [CGRect] = []
        for window in windows where !CFEqual(window, root) {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value)
            // 缺失 subrole 的 Qt 窗口仍可作为观察候选；通信失败不能被解释为弹层。
            guard result == .success || result == .attributeUnsupported || result == .noValue else { return nil }
            guard excludesAXWindow(subrole: value as? String) else { continue }
            if let id = SkyLightSPI.shared.windowID(for: window) {
                ids.insert(id)
            } else if let frame = axFrame(window) {
                // SPI 无法映射时用精确几何排除；未知几何则不发放任何候选。
                bounds.append(frame)
            } else {
                return nil
            }
        }
        return (ids, bounds)
    }

    static func excludesAXWindow(subrole: String?) -> Bool {
        // AXWindow/AXParent 都不是 WindowServer 所有权证明，只排除明确的普通窗口。
        subrole == kAXStandardWindowSubrole as String
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
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
        let frame = CGRect(origin: point, size: dimensions)
        return validBounds(frame) ? frame : nil
    }

    private static func captureImage(_ window: Window, config: ImageCaptureConfig) throws -> CGImage? {
        if let image = SkyLightSPI.shared.hardwareCaptureWindow(window.windowID) { return image }
        return try BlockingAsyncBridge.run(timeout: config.captureTimeout) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: {
                $0.windowID == window.windowID && $0.owningApplication?.processID == window.pid && $0.frame == window
                    .bounds
            }) else { return nil }
            let configuration = SCStreamConfiguration()
            // 备用截图采用点分辨率；对外尺寸始终从最终编码图片读取。
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
