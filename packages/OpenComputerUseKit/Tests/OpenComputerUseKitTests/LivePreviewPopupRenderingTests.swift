import CoreGraphics
import CoreVideo
import Foundation
@testable import OpenComputerUseKit
import Testing

struct LivePreviewPopupRenderingTests {
    @Test func `popup capture keeps alpha while root retains its background and cross Space mode`() {
        let size = CGSize(width: 314, height: 350)
        let popup = LivePreviewCapture.configuration(for: size, transparent: true)
        let root = LivePreviewCapture.configuration(for: size)
        #expect(popup.backgroundColor.alpha == 0)
        #expect(root.backgroundColor.alpha == 1)
        #expect(popup.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(!popup.shouldBeOpaque)
        #expect(root.ignoreGlobalClipSingleWindow && popup.ignoreGlobalClipSingleWindow)
        #expect(popup.width == root.width && popup.height == root.height)
    }

    @Test func `display crop uses local points for negative and vertically stacked displays`() throws {
        let displays = [CGRect(x: 0, y: 0, width: 1600, height: 900),
                        CGRect(x: -1200, y: -800, width: 1200, height: 800)]
        let menu = CGRect(x: -1100, y: -700, width: 314, height: 350)
        let region = try #require(LivePreviewPopupRegion.displayRegion(window: menu, displays: displays))
        #expect(region.index == 1)
        #expect(region.sourceRect == CGRect(x: 100, y: 100, width: 314, height: 350))
    }

    @Test func `cross display and clipped popup never silently become a partial display crop`() {
        let displays = [CGRect(x: -800, y: 0, width: 800, height: 600),
                        CGRect(x: 0, y: 0, width: 800, height: 600)]
        for window in [CGRect(x: -40, y: 20, width: 80, height: 100),
                       CGRect(x: 10, y: -41, width: 393, height: 481),
                       CGRect.infinite, CGRect.null, CGRect.zero] {
            #expect(LivePreviewPopupRegion.displayRegion(window: window, displays: displays) == nil)
        }
        let smallMenu = CGRect(x: 17, y: 43, width: 66, height: 20)
        #expect(LivePreviewPopupRegion.displayRegion(window: smallMenu, displays: displays) != nil)
    }

    @Test func `independent fallback rejects parent groups and cropped pictures without magic offsets`() {
        let sheet = CGRect(x: 2032, y: 189, width: 880, height: 537)
        let content = CGRect(origin: .zero, size: sheet.size)
        #expect(LivePreviewPopupRegion.matchesIndependentContent(content, window: sheet))
        #expect(!LivePreviewPopupRegion.matchesIndependentContent(CGRect(x: 0, y: 0, width: 980, height: 800),
                                                                  window: sheet))
        #expect(!LivePreviewPopupRegion.matchesIndependentContent(CGRect(x: 0, y: 0, width: 880, height: 496),
                                                                  window: sheet))
        #expect(!LivePreviewPopupRegion.matchesIndependentContent(.infinite, window: sheet))
    }

    @Test func `actual frame geometry rejects expanded groups clipped regions and missing metadata`() {
        let window = CGRect(x: -400, y: -41, width: 393, height: 481)
        let initial = CGRect(origin: .zero, size: window.size)
        #expect(LivePreviewPopupRegion.matchesIndependentContent(initial, window: window))
        for metadata: Any? in [window, window.dictionaryRepresentation, NSValue(rect: window)] {
            #expect(LivePreviewPopupRegion.matchesCapturedFrame(metadata, window: window))
        }
        let expanded = window.union(CGRect(x: -500, y: -100, width: 800, height: 800))
        for metadata: Any? in [expanded, window.offsetBy(dx: 1, dy: 0),
                               CGRect(x: -400, y: 0, width: 393, height: 440), nil,
                               NSNumber(value: 123), NSValue(point: .zero),
                               NSValue(range: NSRange(location: 0, length: 1)),
                               CGRect.infinite] {
            #expect(!LivePreviewPopupRegion.matchesCapturedFrame(metadata, window: window))
        }
    }

    @Test func `transparent popup margin preserves root and genuine black popup content remains black`() throws {
        let root = try bitmap(width: 20, height: 20) { context in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let popup = try bitmap(width: 10, height: 10) { context in
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 3, y: 3, width: 4, height: 4))
        }
        #expect(LivePreviewPopup.hasVisibleContent(popup))
        let bounds = CGRect(x: -50, y: -80, width: 20, height: 20)
        let window = LivePreviewPopup.Window(windowID: 2, pid: 1,
                                             bounds: CGRect(x: -45, y: -75, width: 10, height: 10))
        let result = try #require(LivePreviewPopup.composite(root: root, bounds: bounds,
                                                             layers: [.init(window: window, image: popup)]))
        // 2x 输出：弹层矩形内部的透明边缘必须仍为 root 白色，不能变成黑块。
        #expect(try pixel(result, x: 12, y: 12) == [255, 255, 255, 255])
        #expect(try pixel(result, x: 20, y: 20) == [0, 0, 0, 255])
    }

    @Test func `fully transparent capture retires an old popup without expanding the canvas`() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = try #require(LivePreviewTarget(pid: 1, windowID: 1, bounds: bounds))
        let root = LivePreviewPopup.Window(windowID: 1, pid: 1, bounds: bounds)
        let popup = LivePreviewPopup.Window(windowID: 2, pid: 1,
                                            bounds: CGRect(x: 90, y: 90, width: 66, height: 20))
        let clear = try bitmap(width: 66, height: 20) { _ in }
        #expect(!LivePreviewPopup.hasVisibleContent(clear))
        let windows = [popup, root]
        let layers = await LivePreviewPopupCapture.collect(target: target, expected: windows, dependencies: .init(
            readState: { .init(windows: windows) }, readWindows: { windows }, capture: { _ in clear }
        ))
        #expect(layers.isEmpty)
        #expect(LivePreviewPopup.canvas(root: bounds, layers: layers) == bounds)
        var state = LivePreviewPopupState()
        state.observe(windows, now: 0)
        let initial = state.begin(now: 0)
        let first = try #require(initial)
        state.finish(first, layers: [.init(window: popup, image: clear)], now: 0.1)
        let pending = state.begin(now: 0.3)
        let next = try #require(pending)
        state.finish(next, layers: layers, now: 0.4)
        #expect(state.layers.isEmpty)
    }

    private func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return try #require(context.makeImage())
    }

    private func pixel(_ image: CGImage, x column: Int, y row: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = row * context.bytesPerRow + column * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}
