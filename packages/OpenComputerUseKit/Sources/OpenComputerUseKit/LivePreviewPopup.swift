import CoreGraphics
import Foundation

/// 只承载本地预览像素；不产生输入 token，也不改变 agent 的 root 坐标。
enum LivePreviewPopup {
    typealias Window = HoverPopupObservation.Window
    typealias State = HoverPopupObservation.State

    static let refreshInterval: TimeInterval = 0.25
    static let lifetime: TimeInterval = 0.75
    static let maximumCount = 4

    struct Layer {
        let window: Window
        let image: CGImage
    }

    static func hasVisibleContent(_ image: CGImage) -> Bool {
        // 仅检查 alpha；全透明辅助窗不应扩张画布，真实黑色菜单和小弹层仍保留。
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return false }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.clear(rect)
        context.draw(image, in: rect)
        for row in 0 ..< image.height {
            let bytes = UnsafeRawBufferPointer(start: data + row * context.bytesPerRow, count: image.width * 4)
            if stride(from: 3, to: bytes.count, by: 4).contains(where: { bytes[$0] != 0 }) { return true }
        }
        return false
    }

    static func candidates(target: LivePreviewTarget, state: State) -> [Window] {
        guard state.windows.count(where: { $0.windowID == target.windowID }) == 1,
              let index = state.windows.firstIndex(where: { $0.windowID == target.windowID }),
              state.windows[index].pid == target.pid,
              state.windows[index].isVisible,
              state.windows[index].bounds == target.bounds else { return [] }
        return state.windows[..<index].filter { window in
            window.pid == target.pid && window.isVisible && window.layer >= 0
                && state.windows.count(where: { $0.windowID == window.windowID }) == 1
                && !state.independentWindowIDs.contains(window.windowID)
                && !state.independentWindowBounds.contains(window.bounds)
                && HoverPopupObservation.geometricallyRelated(window.bounds, target.bounds)
                && boundedCanvas(target.bounds.union(window.bounds), root: target.bounds)
        }
    }

    static func boundedCanvas(_ canvas: CGRect, root: CGRect) -> Bool {
        // 限制离谱弹层几何；最终位图另外限制为 960px 长边。
        canvas.width.isFinite && canvas.height.isFinite
            && canvas.width <= root.width * 2 && canvas.height <= root.height * 2
    }

    static func canvas(root: CGRect, layers: [Layer]) -> CGRect {
        layers.reduce(root) { $0.union($1.window.bounds) }
    }

    static func destination(_ window: CGRect, canvas: CGRect) -> CGRect {
        CGRect(x: window.minX - canvas.minX, y: canvas.maxY - window.maxY,
               width: window.width, height: window.height)
    }

    static func composite(root: CGImage, bounds: CGRect, layers: [Layer]) -> CGImage? {
        guard !layers.isEmpty else { return root }
        let canvas = canvas(root: bounds, layers: layers)
        guard boundedCanvas(canvas, root: bounds) else { return nil }
        let scale = min(2, 960 / max(canvas.width, canvas.height))
        let width = max(1, Int(canvas.width * scale))
        let height = max(1, Int(canvas.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // union 画布中不属于任何窗口的区域必须保持透明，不能填成预览黑框。
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / canvas.width, y: CGFloat(height) / canvas.height)
        context.draw(root, in: destination(bounds, canvas: canvas))
        // WindowServer 列表是前到后，绘制顺序必须反转。
        for layer in layers.reversed() {
            context.draw(layer.image, in: destination(layer.window.bounds, canvas: canvas))
        }
        return context.makeImage()
    }
}

/// metadata 变化立即撤销所有弹层；过期检查独立于 root 的 complete/idle 帧。
struct LivePreviewPopupState {
    static func needsRender(previousBounds: CGRect?, bounds: CGRect, popupInvalidated: Bool) -> Bool {
        // idle 帧不会更新画布；root 平移也必须重映射坐标并清除旧光标。
        previousBounds != bounds || popupInvalidated
    }

    struct Request {
        let revision: UUID
        let windows: [LivePreviewPopup.Window]
        let startedAt: TimeInterval
    }

    private(set) var layers: [LivePreviewPopup.Layer] = []
    private(set) var windows: [LivePreviewPopup.Window] = []
    private var revision = UUID()
    private var lastRequest = -TimeInterval.infinity
    private var expiresAt = -TimeInterval.infinity
    private var inFlight = false

    mutating func reset() {
        self = Self()
    }

    /// nil 仅表示 root 失效；弹层元数据缺失或应用隐藏只撤销弹层。
    mutating func updateTarget(
        _ target: LivePreviewTarget, appIsHidden: Bool, now: TimeInterval,
        readBounds: (LivePreviewTarget) -> CGRect? = { LivePreviewCapture.currentBounds($0) },
        readWindows: (pid_t) -> [LivePreviewPopup.Window]? = LivePreviewPopupCapture.windows
    ) -> (bounds: CGRect, invalidated: Bool)? {
        guard let bounds = readBounds(target) else {
            observe([], now: now)
            return nil
        }
        var windows = appIsHidden ? [] : (readWindows(target.pid) ?? [])
        let roots = windows.filter { $0.windowID == target.windowID }
        if roots.count != 1 || roots.first?.pid != target.pid || roots.first?.bounds != bounds
            || roots.first?.isVisible != true {
            windows = []
        }
        return (bounds, observe(windows, now: now))
    }

    @discardableResult
    mutating func observe(_ windows: [LivePreviewPopup.Window], now: TimeInterval) -> Bool {
        var changed = false
        if self.windows != windows {
            self.windows = windows
            revision = UUID()
            inFlight = false
            changed = !layers.isEmpty
            layers = []
        }
        if now >= expiresAt, !layers.isEmpty {
            layers = []
            changed = true
        }
        return changed
    }

    mutating func begin(now: TimeInterval) -> Request? {
        guard !inFlight, now - lastRequest >= LivePreviewPopup.refreshInterval else { return nil }
        inFlight = true
        lastRequest = now
        return Request(revision: revision, windows: windows, startedAt: now)
    }

    @discardableResult
    mutating func finish(_ request: Request, layers: [LivePreviewPopup.Layer], now: TimeInterval) -> Bool {
        guard request.revision == revision, request.windows == windows else { return false }
        inFlight = false
        guard now >= request.startedAt, now - request.startedAt < LivePreviewPopup.lifetime else {
            let changed = !self.layers.isEmpty
            self.layers = []
            return changed
        }
        self.layers = layers
        expiresAt = request.startedAt + LivePreviewPopup.lifetime
        return true
    }
}
