import CoreGraphics
import Foundation
@testable import OpenComputerUseKit
import Testing

struct LivePreviewRootLifecycleTests {
    private typealias Window = LivePreviewPopup.Window
    private let bounds = CGRect(x: -800, y: -100, width: 600, height: 400)

    private var target: LivePreviewTarget {
        get throws { try #require(LivePreviewTarget(pid: 123, windowID: 10, bounds: bounds)) }
    }

    private var root: Window {
        Window(windowID: 10, pid: 123, bounds: bounds)
    }

    private var popup: Window {
        Window(windowID: 11, pid: 123, bounds: CGRect(x: -240, y: -60, width: 120, height: 60))
    }

    private func row(
        id: UInt32 = 10, pid: Int32 = 123, bounds: CGRect? = nil, onScreen: Bool = true
    ) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: (bounds ?? self.bounds).dictionaryRepresentation,
         kCGWindowIsOnscreen as String: onScreen]
    }

    private func seededState() throws -> (LivePreviewPopupState, CGImage) {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let pixels = try #require(context.makeImage())
        var state = LivePreviewPopupState()
        state.observe([popup, root], now: 0)
        let pending = state.begin(now: 0)
        let request = try #require(pending)
        state.finish(request, layers: [.init(window: popup, image: pixels)], now: 0.1)
        return (state, pixels)
    }

    @Test func `root query includes bound ID and ignores on screen alpha and popup metadata`() throws {
        let target = try target
        var offscreen = row(onScreen: false)
        offscreen[kCGWindowAlpha as String] = 0
        let minimal: [String: Any] = [
            kCGWindowNumber as String: target.windowID,
            kCGWindowOwnerPID as String: target.pid,
            kCGWindowBounds as String: bounds.dictionaryRepresentation
        ]
        for metadata in [row(), offscreen, minimal] {
            var reads = 0
            let result = LivePreviewCapture.currentBounds(target) { options, id in
                reads += 1
                #expect(options == .optionIncludingWindow)
                #expect(id == target.windowID)
                return [metadata]
            }
            #expect(result == bounds)
            #expect(reads == 1)
        }
    }

    @Test func `cross Space keeps root bounds and pixels while retiring popup and late capture`() throws {
        let target = try target
        var (state, pixels) = try seededState()
        let pending = state.begin(now: 0.3)
        let request = try #require(pending)
        var reads = 0
        let result = state.updateTarget(target, appIsHidden: false, now: 0.4, readBounds: {
            LivePreviewCapture.currentBounds($0) { options, id in
                #expect(options == .optionIncludingWindow && id == target.windowID)
                return [row(onScreen: false)]
            }
        }, readWindows: { pid in
            #expect(pid == target.pid)
            reads += 1
            // 当前 Space 仍可能有同 PID 窗口；它们不能让旧 popup 留在 root 上。
            return [popup]
        })
        let update = try #require(result)
        #expect(update.bounds == bounds && update.invalidated)
        #expect(reads == 1 && state.layers.isEmpty && state.windows.isEmpty)
        #expect(LivePreviewPopup.composite(root: pixels, bounds: update.bounds, layers: state.layers) === pixels)
        let accepted = state.finish(request, layers: [.init(window: popup, image: pixels)], now: 0.5)
        #expect(!accepted)
    }

    @Test func `hidden app retains root and resumes popup refresh without republishing target`() throws {
        let target = try target
        var (state, pixels) = try seededState()
        let pending = state.begin(now: 0.3)
        let oldRequest = try #require(pending)
        let hidden = state.updateTarget(target, appIsHidden: true, now: 0.4, readBounds: {
            LivePreviewCapture.currentBounds($0) { _, _ in [row(onScreen: false)] }
        }, readWindows: { _ in
            Issue.record("隐藏期间不应枚举 popup")
            return [popup, root]
        })
        #expect(hidden?.bounds == bounds && hidden?.invalidated == true)
        #expect(state.layers.isEmpty)
        let restored = state.updateTarget(target, appIsHidden: false, now: 0.6, readBounds: {
            LivePreviewCapture.currentBounds($0) { _, _ in [row()] }
        }, readWindows: { _ in [popup, root] })
        #expect(restored?.bounds == bounds)
        let acceptedOld = state.finish(oldRequest, layers: [.init(window: popup, image: pixels)], now: 0.61)
        #expect(!acceptedOld)
        let next = state.begin(now: 0.62)
        let request = try #require(next)
        let acceptedNew = state.finish(request, layers: [.init(window: popup, image: pixels)], now: 0.7)
        #expect(acceptedNew && state.layers.count == 1)
    }

    @Test func `popup query failure keeps root and recovers with unchanged window list`() throws {
        let target = try target
        var (state, pixels) = try seededState()
        let pending = state.begin(now: 0.3)
        let old = try #require(pending)
        let unavailable = state.updateTarget(target, appIsHidden: false, now: 0.4,
                                             readBounds: { _ in bounds }, readWindows: { _ in nil })
        #expect(unavailable?.bounds == bounds && unavailable?.invalidated == true)
        #expect(state.layers.isEmpty)
        let recovered = state.updateTarget(target, appIsHidden: false, now: 0.6,
                                           readBounds: { _ in bounds }, readWindows: { _ in [popup, root] })
        #expect(recovered != nil)
        let accepted = state.finish(old, layers: [.init(window: popup, image: pixels)], now: 0.61)
        #expect(!accepted)
        let next = state.begin(now: 0.62)
        #expect(next != nil)
    }

    @Test func `real close and wrong root identity invalidate monitor even with cached visible popup`() throws {
        let target = try target
        var missingBounds = row()
        missingBounds.removeValue(forKey: kCGWindowBounds as String)
        let invalidRows: [[[String: Any]]?] = [
            [], nil, [row(id: 99)], [row(pid: 456)], [missingBounds],
            [row(bounds: CGRect(x: 0, y: 0, width: 0, height: 400))]
        ]
        for rows in invalidRows {
            var (state, _) = try seededState()
            let result = state.updateTarget(target, appIsHidden: false, now: 0.4, readBounds: {
                LivePreviewCapture.currentBounds($0) { _, _ in rows }
            }, readWindows: { _ in
                Issue.record("root 已失效时不应再查询 popup")
                return [popup, root]
            })
            // monitor 仅在这里得到 nil 并撤销 target，不能被旧的 on-screen 列表救回。
            #expect(result == nil)
            #expect(state.layers.isEmpty && state.windows.isEmpty)
        }
    }

    @Test func `offscreen root geometry still drives resize and invalidates old popup`() throws {
        let target = try target
        let resized = CGRect(x: -900, y: -200, width: 700, height: 500)
        var (state, _) = try seededState()
        let result = state.updateTarget(target, appIsHidden: false, now: 0.4, readBounds: {
            LivePreviewCapture.currentBounds($0) { _, _ in [row(bounds: resized, onScreen: false)] }
        }, readWindows: { _ in [popup, root] })
        #expect(result?.bounds == resized && result?.invalidated == true)
        #expect(state.layers.isEmpty)
    }

    @Test func `idle root translation without popup redraws cached pixels in the new canvas`() throws {
        let target = try target
        let (_, pixels) = try seededState()
        let moved = bounds.offsetBy(dx: 150, dy: -60)
        var state = LivePreviewPopupState()
        state.observe([root], now: 0)
        let result = state.updateTarget(target, appIsHidden: false, now: 0.1,
                                        readBounds: { _ in moved }, readWindows: { _ in
                                            [Window(windowID: root.windowID, pid: root.pid, bounds: moved)]
                                        })
        let update = try #require(result)
        // 没有新 root 帧、没有 popup 失效，只有几何变化能驱动这次重绘。
        #expect(!update.invalidated && state.layers.isEmpty)
        #expect(update.bounds.size == bounds.size)
        let redraw = LivePreviewPopupState.needsRender(
            previousBounds: bounds, bounds: update.bounds, popupInvalidated: update.invalidated
        )
        #expect(redraw)
        var canvas = bounds
        if redraw {
            #expect(LivePreviewPopup.composite(root: pixels, bounds: update.bounds, layers: state.layers) === pixels)
            canvas = LivePreviewPopup.canvas(root: update.bounds, layers: state.layers)
        }
        #expect(canvas == moved && canvas != bounds)
        let local = CGPoint(x: 100, y: 80)
        let tip = CGPoint(x: moved.minX + local.x, y: 1000 - moved.maxY + local.y)
        #expect(livePreviewCursorPoint(tip: tip, window: canvas, primaryHeight: 1000) == local)
        #expect(livePreviewCursorPoint(tip: tip, window: bounds, primaryHeight: 1000) != local)
        // 下一轮仍 idle 且几何不变时不重复重绘；popup 撤销仍能独立触发。
        #expect(!LivePreviewPopupState.needsRender(previousBounds: canvas, bounds: moved, popupInvalidated: false))
        #expect(LivePreviewPopupState.needsRender(previousBounds: canvas, bounds: moved, popupInvalidated: true))
    }
}
