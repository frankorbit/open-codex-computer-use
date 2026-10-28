import CoreGraphics
import CoreVideo
import Foundation
@testable import OpenComputerUseKit
import ScreenCaptureKit
import Testing

struct LivePreviewPopupRenderingTests {
    @Test func `root and popup capture preserve alpha and cross Space mode`() {
        let size = CGSize(width: 314, height: 350)
        let popup = LivePreviewCapture.configuration(for: size, transparent: true)
        let root = LivePreviewCapture.configuration(for: size)
        #expect(popup.backgroundColor.alpha == 0)
        #expect(root.backgroundColor.alpha == 0)
        #expect(!root.shouldBeOpaque)
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

    @Test func `hardware popup capture returns only a full window image of the requested window`() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let sheet = CGRect(x: 775, y: 419, width: 370, height: 182)
        var requested: [CGWindowID] = []
        // Numbers 保存面板实测：硬件缓冲区 740×364（2 倍屏），只含面板本身。
        let image = try #require(PopupWindowImage.hardware(3067, bounds: sheet, displays: [display]) { id in
            requested.append(id)
            return try? bitmap(width: 740, height: 364) { _ in }
        })
        #expect(requested == [3067])
        #expect(image.width == 740 && image.height == 364)
        // 裁剪或比例不符的图片、硬件采集不可用时都不返回，由调用方退回显示器裁剪。
        for size in [(740, 300), (2520, 1920), (370, 364)] {
            #expect(PopupWindowImage.hardware(3067, bounds: sheet, displays: [display]) { _ in
                try? bitmap(width: size.0, height: size.1) { _ in }
            } == nil)
        }
        #expect(PopupWindowImage.hardware(3067, bounds: sheet, displays: [display]) { _ in nil } == nil)
    }

    @Test func `hardware popup capture is skipped when the window is not inside one display`() {
        let displays = [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 800, y: 0, width: 800, height: 600)]
        // 跨屏、部分离屏、无显示器信息或几何无效时，即便比例恰好相同也不读硬件缓冲区。
        for (bounds, screens) in [(CGRect(x: 700, y: 100, width: 200, height: 100), displays),
                                  (CGRect(x: -40, y: 100, width: 200, height: 100), displays),
                                  (CGRect(x: 100, y: 100, width: 200, height: 100), []),
                                  (CGRect.null, displays), (CGRect.infinite, displays)] {
            #expect(PopupWindowImage.hardware(1, bounds: bounds, displays: screens) { _ in
                Issue.record("hardware capture must not run for \(bounds)")
                return nil
            } == nil)
        }
    }

    @Test func `popup alpha mask keeps the popup's own shape over an opaque backdrop`() throws {
        // 带底色渲染的弹层整块不透明；按硬件缓冲区（2 倍尺寸）的透明度裁回：左半弹层、右半圆角外。
        let rendered = try bitmap(width: 4, height: 2) { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        }
        let mask = try bitmap(width: 8, height: 4) { context in
            context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let result = try #require(PopupWindowImage.masked(rendered, alphaFrom: mask))
        let source = try pixel(PopupWindowImage.masked(rendered, alphaFrom: rendered) ?? rendered, x: 1, y: 1)
        #expect(result.width == 4 && result.height == 2)
        #expect(try pixel(result, x: 0, y: 0)[3] == 255)
        #expect(try pixel(result, x: 0, y: 1) == source, "opaque mask keeps the rendered light material")
        #expect(source[0] > 180, "the material stays light")
        #expect(try pixel(result, x: 3, y: 0) == [0, 0, 0, 0], "transparent mask clears the backdrop")
        // 半透明处按比例淡出（预乘）。
        let half = try bitmap(width: 4, height: 2) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        }
        let faded = try #require(PopupWindowImage.masked(rendered, alphaFrom: half))
        let value = try pixel(faded, x: 2, y: 1)
        #expect((126 ... 130).contains(Int(value[3])))
        #expect(abs(Int(value[0]) - Int(source[0]) / 2) <= 2, "premultiplied color fades with the alpha")
    }

    @Test func `popup backdrop follows the system appearance and is opaque`() {
        let light = PopupWindowImage.backdrop(darkMode: false)
        let dark = PopupWindowImage.backdrop(darkMode: true)
        #expect(light.alpha == 1 && dark.alpha == 1)
        #expect((light.components?.first ?? 0) > 0.8)
        #expect((dark.components?.first ?? 1) < 0.3)
    }

    @Test func `screenshot samples without frame status are accepted but incomplete frames are not`() {
        // SCScreenshotManager 的单张截图样本不带帧状态（Numbers 保存面板实测为 nil）。
        #expect(PopupWindowImage.frameIsComplete(nil))
        #expect(PopupWindowImage.frameIsComplete([]))
        #expect(PopupWindowImage.frameIsComplete([[:]]))
        #expect(PopupWindowImage.frameIsComplete([[.status: SCFrameStatus.complete.rawValue]]))
        for status in [SCFrameStatus.idle, .blank, .suspended, .started, .stopped] {
            #expect(!PopupWindowImage.frameIsComplete([[.status: status.rawValue]]))
        }
        #expect(!PopupWindowImage.frameIsComplete([[.status: "complete"]]))
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
