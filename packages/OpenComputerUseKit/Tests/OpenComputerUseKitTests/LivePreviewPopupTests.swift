import CoreGraphics
import Foundation
@testable import OpenComputerUseKit
import Testing

struct LivePreviewPopupTests {
    private typealias Popup = LivePreviewPopup
    private typealias Window = Popup.Window
    private let root = Window(windowID: 10, pid: 123, bounds: CGRect(x: -800, y: -100, width: 600, height: 400))
    private let popup = Window(windowID: 11, pid: 123, bounds: CGRect(x: -240, y: -60, width: 120, height: 60))

    private var target: LivePreviewTarget {
        get throws { try #require(LivePreviewTarget(pid: root.pid, windowID: root.windowID, bounds: root.bounds)) }
    }

    private func image(
        _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 4, height: Int = 4
    ) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func `only visible related same PID windows ahead of root are candidates`() throws {
        let otherApp = Window(windowID: 12, pid: 999, bounds: popup.bounds)
        let standard = Window(windowID: 13, pid: 123, bounds: popup.bounds)
        let fallbackStandard = Window(windowID: 14, pid: 123,
                                      bounds: CGRect(x: -240, y: 0, width: 120, height: 60))
        let distant = Window(windowID: 15, pid: 123, bounds: CGRect(x: 100, y: 0, width: 120, height: 60))
        let behind = Window(windowID: 16, pid: 123, bounds: popup.bounds)
        let windows = [otherApp, standard, fallbackStandard, distant, popup, root, behind]
        let state = Popup.State(windows: windows, independentWindowIDs: [13],
                                independentWindowBounds: [fallbackStandard.bounds], rootIsForeground: false)
        #expect(try Popup.candidates(target: target, state: state) == [popup])
        var hidden = popup
        hidden.isOnscreen = false
        var transparent = popup
        transparent.alpha = 0
        var negativeLayer = popup
        negativeLayer.layer = -1
        for invalid in [hidden, transparent, negativeLayer] {
            #expect(try Popup.candidates(target: target, state: .init(windows: [invalid, root])).isEmpty)
        }
    }

    @Test func `duplicate identities invalid root and enormous geometry fail closed`() throws {
        #expect(try Popup.candidates(target: target, state: .init(windows: [popup, popup, root])).isEmpty)
        #expect(try Popup.candidates(target: target, state: .init(windows: [popup, root, root])).isEmpty)
        var hiddenRoot = root
        hiddenRoot.isOnscreen = false
        #expect(try Popup.candidates(target: target, state: .init(windows: [popup, hiddenRoot])).isEmpty)
        let moved = Window(windowID: root.windowID, pid: root.pid, bounds: root.bounds.offsetBy(dx: 1, dy: 0))
        #expect(try Popup.candidates(target: target, state: .init(windows: [popup, moved])).isEmpty)
        let giant = Window(windowID: 20, pid: root.pid, bounds: CGRect(x: -800, y: -100, width: 1e20, height: 50))
        #expect(try Popup.candidates(target: target, state: .init(windows: [giant, root])).isEmpty)
        let infinite = Window(windowID: 21, pid: root.pid, bounds: .infinite)
        #expect(try Popup.candidates(target: target, state: .init(windows: [infinite, root])).isEmpty)
    }

    @Test func `request rate bounded and idle root cannot retain expired popup`() throws {
        var state = LivePreviewPopupState()
        state.observe([popup, root], now: 10)
        let initialRequest = state.begin(now: 10)
        let request = try #require(initialRequest)
        let overlappingRequest = state.begin(now: 11)
        #expect(overlappingRequest == nil)
        try state.finish(request, layers: [.init(window: popup, image: image(1, 0, 0))], now: 10.1)
        #expect(state.layers.count == 1)
        let tooEarlyRequest = state.begin(now: 10.24)
        #expect(tooEarlyRequest == nil)
        let nextRequest = state.begin(now: 10.25)
        #expect(nextRequest != nil)
        let beforeExpiry = state.observe([popup, root], now: 10.74)
        #expect(!beforeExpiry)
        let didExpire = state.observe([popup, root], now: 10.75)
        #expect(didExpire)
        #expect(state.layers.isEmpty)
    }

    @Test func `close reopen geometry and lifecycle changes reject late results`() throws {
        let layer = try Popup.Layer(window: popup, image: image(1, 0, 0))
        var state = LivePreviewPopupState()
        state.observe([popup, root], now: 0)
        let firstRequest = state.begin(now: 0)
        let first = try #require(firstRequest)
        state.finish(first, layers: [layer], now: 0.1)
        let pendingRequest = state.begin(now: 0.3)
        let pending = try #require(pendingRequest)
        let didClose = state.observe([root], now: 0.4)
        #expect(didClose)
        state.observe([popup, root], now: 0.5)
        let acceptedAfterClose = state.finish(pending, layers: [layer], now: 0.6)
        #expect(!acceptedAfterClose)
        #expect(state.layers.isEmpty)
        let reopenedRequest = state.begin(now: 0.6)
        let reopened = try #require(reopenedRequest)
        state.reset()
        state.observe([popup, root], now: 0.7)
        let acceptedAfterReset = state.finish(reopened, layers: [layer], now: 0.71)
        #expect(!acceptedAfterReset)
        let resetRequest = state.begin(now: 0.8)
        let afterReset = try #require(resetRequest)
        let moved = Window(windowID: popup.windowID, pid: popup.pid, bounds: popup.bounds.offsetBy(dx: 1, dy: 0))
        state.observe([moved, root], now: 0.9)
        let acceptedAfterMove = state.finish(afterReset, layers: [layer], now: 1)
        #expect(!acceptedAfterMove)
        #expect(state.layers.isEmpty)
    }

    @Test func `slow or failed refresh removes previous pixels`() throws {
        var state = LivePreviewPopupState()
        state.observe([popup, root], now: 0)
        let initialRequest = state.begin(now: 0)
        let request = try #require(initialRequest)
        try state.finish(request, layers: [.init(window: popup, image: image(1, 0, 0))], now: 0.1)
        let slowRequest = state.begin(now: 0.3)
        let slow = try #require(slowRequest)
        try state.finish(slow, layers: [.init(window: popup, image: image(1, 0, 0))], now: 1.1)
        #expect(state.layers.isEmpty)
        let failedRequest = state.begin(now: 1.2)
        let failed = try #require(failedRequest)
        state.finish(failed, layers: [], now: 1.3)
        #expect(state.layers.isEmpty)
    }

    @Test func `capture revalidates metadata and AX exclusions after screenshot`() async throws {
        let windows = [popup, root]
        let pixels = try image(1, 0, 0)
        var reads = 0
        let result = try await LivePreviewPopupCapture.collect(target: target, expected: windows, dependencies: .init(
            readState: {
                reads += 1
                return Popup.State(windows: windows, independentWindowIDs: reads > 1 ? [popup.windowID] : [])
            }, readWindows: { windows }, capture: { _ in pixels }
        ))
        #expect(result.isEmpty)
        #expect(reads == 2)
    }

    @Test func `no capture when metadata unavailable hidden or changed`() async throws {
        let windows = [popup, root]
        var captures = 0
        let unavailable = try await LivePreviewPopupCapture.collect(
            target: target,
            expected: windows,
            dependencies: .init(
                readState: { nil }, readWindows: { windows }, capture: { _ in captures += 1; return nil }
            )
        )
        #expect(unavailable.isEmpty)
        let changed = try await LivePreviewPopupCapture.collect(target: target, expected: windows, dependencies: .init(
            readState: { Popup.State(windows: windows) }, readWindows: { [root] },
            capture: { _ in captures += 1; return nil }
        ))
        #expect(changed.isEmpty)
        #expect(captures == 0)
    }

    @Test func `screenshots bounded and close during capture discards batch`() async throws {
        let popups = (20 ..< 28).map { Window(windowID: UInt32($0), pid: root.pid, bounds: popup.bounds) }
        let windows = popups + [root]
        let pixels = try image(1, 0, 0)
        var captures = 0
        let result = try await LivePreviewPopupCapture.collect(target: target, expected: windows, dependencies: .init(
            readState: { Popup.State(windows: windows) }, readWindows: { windows },
            capture: { _ in captures += 1; return pixels }
        ))
        #expect(captures == 4)
        #expect(result.map(\.window) == Array(popups.prefix(4)))
        var closed = false
        let dropped = try await LivePreviewPopupCapture.collect(
            target: target,
            expected: [popup, root],
            dependencies: .init(
                readState: { Popup.State(windows: closed ? [root] : [popup, root]) },
                readWindows: { closed ? [root] : [popup, root] },
                capture: { _ in closed = true; return pixels }
            )
        )
        #expect(dropped.isEmpty)
    }

    @Test func `metadata churn does not bypass rate limit and reordering retires old pixels`() throws {
        var state = LivePreviewPopupState()
        state.observe([popup, root], now: 0)
        let pending = state.begin(now: 0)
        let request = try #require(pending)
        try state.finish(request, layers: [.init(window: popup, image: image(1, 0, 0))], now: 0.01)
        state.observe([root, popup], now: 0.1)
        let tooEarly = state.begin(now: 0.1)
        #expect(tooEarly == nil)
        #expect(state.layers.isEmpty)
        #expect(try Popup.candidates(target: target, state: .init(windows: [root, popup])).isEmpty)
    }

    @Test func `capture error and missing final metadata cannot keep cached pixels`() async throws {
        enum CaptureFailure: Error { case unavailable }
        var reads = 0
        let windows = [popup, root]
        let failed = try await LivePreviewPopupCapture.collect(target: target, expected: windows, dependencies: .init(
            readState: {
                reads += 1
                return reads == 1 ? Popup.State(windows: windows) : nil
            }, readWindows: { windows }, capture: { _ in throw CaptureFailure.unavailable }
        ))
        #expect(failed.isEmpty)
        #expect(reads == 2)
    }

    @Test func `expanded canvas preserves size constraints and root cursor mapping`() throws {
        let layers = try [Popup.Layer(window: popup, image: image(1, 0, 0))]
        let canvas = Popup.canvas(root: root.bounds, layers: layers)
        let result = try #require(Popup.composite(root: image(0, 0, 0), bounds: root.bounds, layers: layers))
        #expect(max(result.width, result.height) <= 960)
        let screen = CGRect(x: -800, y: -400, width: 800, height: 500)
        let pip = LivePreviewLayout.sourceChangeFrame(
            aspect: canvas.size, current: CGRect(x: 0, y: 0, width: 360, height: 240), visibleFrame: screen
        )
        #expect(screen.contains(pip))
        #expect(pip.height <= 480)
        // 扩展只影响 PIP 的绘制坐标，root 本身的 agent 截图坐标保持不变。
        let tip = CGPoint(x: -500, y: 900)
        let rootPoint = try #require(livePreviewCursorPoint(tip: tip, window: root.bounds, primaryHeight: 1000))
        let canvasPoint = try #require(livePreviewCursorPoint(tip: tip, window: canvas, primaryHeight: 1000))
        let offset = Popup.destination(root.bounds, canvas: canvas).origin
        #expect(canvasPoint == CGPoint(x: rootPoint.x + offset.x, y: rootPoint.y + offset.y))
    }
}

extension LivePreviewPopupTests {
    @Test func `missing WPS root AX keeps CG bound candidates while unknown standards fail closed`() throws {
        let standard = Window(windowID: 15, pid: root.pid, bounds: root.bounds.offsetBy(dx: 20, dy: 20))
        let windows = [popup, standard, root]
        let missingRoot = try #require(LivePreviewPopupCapture.classifiedState(
            target: target, windows: windows, axWindows: [
                .init(windowID: standard.windowID, bounds: nil, isStandard: true)
            ]
        ))
        #expect(try Popup.candidates(target: target, state: missingRoot) == [popup])
        let missingRootFrame = try #require(LivePreviewPopupCapture.classifiedState(
            target: target, windows: [popup, root], axWindows: [
                .init(windowID: root.windowID, bounds: nil, isStandard: true)
            ]
        ))
        #expect(try Popup.candidates(target: target, state: missingRootFrame) == [popup])
        #expect(try LivePreviewPopupCapture.classifiedState(target: target, windows: windows, axWindows: nil) == nil)
        #expect(try LivePreviewPopupCapture.classifiedState(target: target, windows: windows, axWindows: [
            .init(windowID: nil, bounds: nil, isStandard: true)
        ]) == nil)
        #expect(try LivePreviewPopupCapture.classifiedState(target: target, windows: windows, axWindows: [
            .init(windowID: root.windowID, bounds: root.bounds.offsetBy(dx: 1, dy: 0), isStandard: true)
        ]) == nil)
        let fallback = try #require(LivePreviewPopupCapture.classifiedState(
            target: target, windows: windows, axWindows: [
                .init(windowID: nil, bounds: standard.bounds, isStandard: true)
            ]
        ))
        #expect(try Popup.candidates(target: target, state: fallback) == [popup])
    }

    @Test func `publish after target invalidation restores capture but explicit PIP collapse stays hidden`() throws {
        var state = LivePreviewState()
        _ = try state.select(target)
        let beforeHide = state.generation
        // root 真正失效后撤销 target，后续普通 publish 可以重建流。
        _ = state.select(nil)
        #expect(!state.accepts(beforeHide))
        _ = try state.select(target)
        #expect(state.accepts(state.generation))
        let restored = state.generation
        // 切 app 后，即使旧窗口继续送帧，也不能进入新的 PIP。
        _ = state.select(LivePreviewTarget(pid: 456, windowID: 99, bounds: root.bounds))
        #expect(!state.accepts(restored))
        state.hide()
        _ = state.select(nil)
        _ = try state.select(target)
        #expect(!state.accepts(state.generation))
        state.reset()
        #expect(!state.accepts(restored))
    }

    @Test func `bounded composition workload reports local CPU cost`() throws {
        let rootPixels = try image(0.5, 0.5, 0.5, width: 960, height: 640)
        let popupPixels = try image(0, 1, 0, width: 960, height: 640)
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 640)
        let layers = (1 ... 4).map { index in
            Popup.Layer(window: Window(windowID: UInt32(index), pid: 123, bounds: bounds), image: popupPixels)
        }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< 120 {
            let result = try #require(Popup.composite(root: rootPixels, bounds: bounds, layers: layers))
            #expect(result.width == 960 && result.height == 640)
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 120
        print("PIP composite 960x640 root + 4 full-size layers: \(milliseconds) ms/frame (120 frames)")
    }

    @Test func `composition contains actual popup pixels black exterior and front to back order`() throws {
        let rootBounds = CGRect(x: -100, y: -100, width: 100, height: 100)
        let front = Window(windowID: 1, pid: 123, bounds: CGRect(x: -20, y: -80, width: 40, height: 40))
        let back = Window(windowID: 2, pid: 123, bounds: CGRect(x: -40, y: -80, width: 50, height: 50))
        let layers = try [Popup.Layer(window: front, image: image(0, 1, 0)),
                          Popup.Layer(window: back, image: image(0, 0, 1))]
        let canvas = Popup.canvas(root: rootBounds, layers: layers)
        #expect(canvas == CGRect(x: -100, y: -100, width: 120, height: 100))
        #expect(Popup.destination(front.bounds, canvas: canvas) == CGRect(x: 80, y: 40, width: 40, height: 40))
        let composed = try #require(Popup.composite(root: image(1, 0, 0), bounds: rootBounds, layers: layers))
        #expect(composed.width == 240 && composed.height == 200)
        // 独立 bitmap readback；坐标使用位图左上角，验证上下翻转没有污染布局。
        let bytes = try #require(composed.dataProvider?.data)
        let data = try #require(CFDataGetBytePtr(bytes))
        func pixel(_ column: Int, _ row: Int) -> [UInt8] {
            let offset = row * composed.bytesPerRow + column * 4
            return Array(UnsafeBufferPointer(start: data + offset, count: 4))
        }
        #expect(pixel(20, 20) == [255, 0, 0, 255])
        #expect(pixel(140, 60) == [0, 0, 255, 255])
        #expect(pixel(180, 60) == [0, 255, 0, 255])
        #expect(pixel(220, 180) == [0, 0, 0, 255])
        let rootOnly = try #require(Popup.composite(root: image(1, 0, 0), bounds: rootBounds, layers: []))
        #expect(rootOnly.width == 4 && rootOnly.height == 4)
    }
}
