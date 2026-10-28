import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO

struct HoverPopupObservation {
    let token: String
    let windowID: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    /// 图片实际覆盖的屏幕区域；未知时只能观察，不能根据宽高猜测裁剪偏移。
    var captureBounds: CGRect?
    let imageData: Data
    let pixelSize: CGSize
    var permitsInput = true
    /// 后台凭证必须显式发放；旧观察的 permitsInput 不能升级为后台授权。
    var permitsBackgroundInput = false

    func clickMethod(policy: ExecutionPolicy) -> ClickMethod? {
        guard let captureBounds, Self.validBounds(captureBounds),
              bounds.contains(captureBounds) else { return nil }
        if policy.isBackground { return permitsBackgroundInput ? .skyClick : nil }
        return permitsInput ? .global : nil
    }

    var content: [ToolResultContentItem] {
        guard let policy = try? ExecutionPolicy.current() else {
            var observationOnly = self
            observationOnly.permitsBackgroundInput = false
            return observationOnly.content(policy: .background)
        }
        return content(policy: policy)
    }

    func content(policy: ExecutionPolicy) -> [ToolResultContentItem] {
        let method = clickMethod(policy: policy)
        let canClick = method != nil
        let identity = "Popup candidate: windowID=\(windowID), pid=\(pid)."
            + (canClick ? " popup_token=\"\(token)\"." : " Observation only; no input token.")
        let geometry = "bounds=(\(bounds.minX), \(bounds.minY), \(bounds.width), \(bounds.height)) screen points"
            + " (Quartz top-left, y down); pixelSize=(\(pixelSize.width), \(pixelSize.height))."
            + " captureBounds=\(captureBounds.map { String(describing: $0) } ?? "unknown")."
            + " Main coordinates unchanged."
        let usage = if let method {
            "Image-local pixels: click({popup_token:\"\(token)\",x:...,y:...,click_method:\"\(method.rawValue)\"})"
                + " / JS app.click([x,y],{popupToken:\"\(token)\",clickMethod:\"\(method.rawValue)\"})."
                + " Candidate only, not parent proof; single-use token requires"
                + " live root/popup identity/geometry and route-specific receiver checks; expires after 30 seconds."
                + (method == .skyClick
                    ? " Background targeted left single click only; same-app obstruction checks remain required;"
                        + " no activation, global input or fallback."
                    : " Foreground focus is required for the compatible global left single click.")
                + " Any attempt consumes the observation; unknown input result requires fresh observation."
                + " Never replay."
        } else {
            "Image coordinates are local to this observed window, not the main-window screenshot. "
                + "Same-process geometric candidate only, not proof of popup ownership. "
                + "This observation does not authorize popup input."
                + (captureBounds == nil
                    ? " Capture region is unverified; do not infer a crop offset or click coordinates." : "")
        }
        var image = ToolResultContentItem.screenshotImage(imageData).dictionary
        var metadata: [String: Any] = ["windowID": windowID, "pid": pid, "observationOnly": !canClick]
        if let method {
            metadata["token"] = token
            metadata["clickMethod"] = method.rawValue
            metadata["backgroundClickCapable"] = method == .skyClick
        }
        image["_meta"] = ["ocuPopup": metadata]
        return [.text([identity, geometry, usage].joined(separator: "\n")), ToolResultContentItem(dictionary: image)]
    }

    static let unavailableNote = "Popup observation completed within its supported scope: no verifiable popup candidates were captured. "
        + "This is not an incomplete observation or an input failure. The scope covers visible same-process windows "
        + "near the bound window; it does not prove that no other popup exists. No popup input tokens were issued. "
        + "Do not guess popup coordinates. Main-window targets still require fresh observation and all existing input checks."

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

        func candidates(rootWindowID: CGWindowID, pid: pid_t, rootBounds: CGRect) -> [Window] {
            guard let rootIndex = windows.firstIndex(where: { $0.windowID == rootWindowID }) else { return [] }
            return windows[..<rootIndex].filter { window in
                window.pid == pid && window.isVisible && window.layer >= 0
                    && windows.count(where: { $0.windowID == window.windowID }) == 1
                    && !independentWindowIDs.contains(window.windowID)
                    && !independentWindowBounds.contains(window.bounds)
                    && HoverPopupObservation.geometricallyRelated(window.bounds, rootBounds)
                    && !isSharingIndicator(window)
            }
        }

        /// The window sharing indicator of a streamed window is not an app popup.
        func isSharingIndicator(
            _ window: Window, captured: Set<WindowSharingIndicator.Captured> = WindowSharingIndicator.capturedWindows
        ) -> Bool {
            WindowSharingIndicator.isIndicator(
                windowID: window.windowID, pid: window.pid, bounds: window.bounds, layer: window.layer, captured: captured
            ) { id in windows.first(where: { $0.windowID == id })?.bounds }
        }
    }

    struct CapturedImage {
        let data: Data
        let captureBounds: CGRect?
    }

    struct Dependencies {
        var readState: () -> State?
        var captureImage: (Window) throws -> CapturedImage?
    }

    static func capture(
        rootWindowID: CGWindowID, pid: pid_t, rootBounds: CGRect,
        requireForeground: Bool = true, allowInput: Bool = true,
        allowBackgroundInput: Bool = false, dependencies: Dependencies
    ) -> [HoverPopupObservation] {
        captureResult(
            rootWindowID: rootWindowID, pid: pid, rootBounds: rootBounds,
            requireForeground: requireForeground, allowInput: allowInput,
            allowBackgroundInput: allowBackgroundInput, dependencies: dependencies
        ).popups
    }

    static func captureResult(
        rootWindowID: CGWindowID, pid: pid_t, rootBounds: CGRect,
        requireForeground: Bool = true, allowInput: Bool = true,
        allowBackgroundInput: Bool = false, dependencies: Dependencies,
        budget: HoverPopupBudget? = nil
    ) -> HoverPopupCaptureResult {
        var inputEligible = allowInput
        func readState() -> State? {
            guard budget?.expired != true else { return nil }
            let state = dependencies.readState()
            guard budget?.expired != true else { return nil }
            inputEligible = inputEligible && state?.rootIsForeground == true
            return state
        }
        func validRoot(_ state: State) -> Bool {
            guard !requireForeground || state.rootIsForeground,
                  state.windows.count(where: { $0.windowID == rootWindowID }) == 1,
                  let root = state.windows.first(where: { $0.windowID == rootWindowID }) else { return false }
            return root.pid == pid && root.bounds == rootBounds && root.isVisible
        }
        func candidates(_ state: State) -> [Window] {
            state.candidates(rootWindowID: rootWindowID, pid: pid, rootBounds: rootBounds)
        }
        guard let initial = readState(), validRoot(initial) else { return .incomplete }
        var captured: [(Window, HoverPopupObservation)] = []
        let initialCandidates = candidates(initial)
        var incomplete = initialCandidates.count > 4
        // 同时限制截图尝试次数，避免大量临时窗口导致无界等待。
        for window in initialCandidates.prefix(4) {
            guard let before = readState(), validRoot(before) else { return .incomplete }
            guard candidates(before).contains(window) else { continue }
            let capturedImage: CapturedImage?
            do {
                capturedImage = try dependencies.captureImage(window)
            } catch {
                incomplete = true
                capturedImage = nil
            }
            // 截图失败也复核 root，不能在中途切窗后继续发出其他 token。
            guard let after = readState(), validRoot(after) else { return .incomplete }
            guard candidates(after).contains(window), let capturedImage,
                  let size = pixelSize(of: capturedImage.data) else {
                incomplete = true
                continue
            }
            captured.append((window, HoverPopupObservation(
                token: UUID().uuidString, windowID: window.windowID, pid: window.pid,
                bounds: window.bounds, captureBounds: capturedImage.captureBounds,
                imageData: capturedImage.data, pixelSize: size
            )))
        }
        // 后续截图期间，之前捕获的窗口也可能关闭或迁移。
        guard let final = readState(), validRoot(final) else { return .incomplete }
        let current = candidates(final)
        let popups = captured.filter { current.contains($0.0) }.map {
            var observation = $0.1
            observation.permitsInput = inputEligible
            observation.permitsBackgroundInput = allowBackgroundInput
            return observation
        }
        return HoverPopupCaptureResult(popups: popups, isIncomplete: incomplete || popups.count != captured.count)
    }

    static func geometricallyRelated(_ popup: CGRect, _ root: CGRect) -> Bool {
        guard validBounds(popup), validBounds(root) else { return false }
        let overlapX = min(popup.maxX, root.maxX) - max(popup.minX, root.minX)
        let overlapY = min(popup.maxY, root.maxY) - max(popup.minY, root.minY)
        // 允许贴边及 16pt 的投影重叠间隙；角落相近不代表属于该 root。
        return (overlapX > 0 && overlapY >= -16) || (overlapY > 0 && overlapX >= -16)
    }

    static func validBounds(_ bounds: CGRect) -> Bool {
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
}

extension HoverPopupObservation {
    static func rootMatchesSnapshot(_ snapshot: AppSnapshot, root: AXUIElement) -> Bool {
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
}
