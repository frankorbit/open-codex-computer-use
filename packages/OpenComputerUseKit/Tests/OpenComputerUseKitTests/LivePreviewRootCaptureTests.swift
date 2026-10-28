import CoreGraphics
@testable import OpenComputerUseKit
import ScreenCaptureKit
import Testing

struct LivePreviewRootCaptureTests {
    private let displays = [CGRect(x: 0, y: 0, width: 1600, height: 900),
                            CGRect(x: -1200, y: -800, width: 1200, height: 800)]

    @Test func `visible root crop uses display local points and excludes child windows`() {
        guard #available(macOS 14.2, *) else { return }
        let bounds = CGRect(x: -1100, y: -700, width: 600, height: 400)
        let plan = LivePreviewRootCapture.plan(bounds: bounds, visible: true, displays: displays)
        #expect(plan == .display(frame: displays[1], sourceRect: CGRect(x: 100, y: 100, width: 600, height: 400)))
        #expect(plan.isolatesRoot)
        let configuration = LivePreviewCapture.configuration(for: bounds.size)
        LivePreviewRootCapture.configure(configuration, plan: plan)
        #expect(!configuration.includeChildWindows)
        #expect(configuration.ignoreShadowsDisplay)
        #expect(!configuration.preservesAspectRatio)
        #expect(configuration.sourceRect == CGRect(x: 100, y: 100, width: 600, height: 400))
        #expect(configuration.width == 960 && configuration.height == 640)
    }

    @Test func `cross display offscreen hidden and missing displays keep uncomposited independent stream`() {
        guard #available(macOS 14.2, *) else { return }
        let visible = CGRect(x: 100, y: 100, width: 600, height: 400)
        for (bounds, isVisible, screens) in [
            (CGRect(x: -100, y: -100, width: 600, height: 400), true, displays),
            (CGRect(x: 100, y: -20, width: 600, height: 400), true, displays),
            (visible, false, displays), (visible, true, []),
            (CGRect.zero, true, displays), (CGRect.infinite, true, displays)
        ] {
            let plan = LivePreviewRootCapture.plan(bounds: bounds, visible: isVisible, displays: screens)
            #expect(plan == .independent)
            #expect(!plan.isolatesRoot)
            let configuration = LivePreviewCapture.configuration(for: visible.size)
            LivePreviewRootCapture.configure(configuration, plan: plan)
            #expect(configuration.preservesAspectRatio)
            #expect(configuration.ignoreGlobalClipSingleWindow)
        }
    }

    @Test func `display crop rejects old pixels after translation resize and monitor topology changes`() {
        guard #available(macOS 14.2, *) else { return }
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let plan = LivePreviewRootCapture.plan(bounds: bounds, visible: true, displays: displays)
        #expect(plan.acceptsFrame(captured: bounds, current: bounds))
        #expect(!plan.acceptsFrame(captured: bounds, current: bounds.offsetBy(dx: 10, dy: 0)))
        #expect(!plan.acceptsFrame(captured: bounds, current: CGRect(x: 100, y: 100, width: 601, height: 400)))
        #expect(plan != LivePreviewRootCapture.plan(bounds: bounds, visible: true,
                                                    displays: [CGRect(x: 0, y: 0, width: 1800, height: 1200)]))
        #expect(plan != LivePreviewRootCapture.plan(bounds: bounds, visible: false, displays: displays))
        #expect(LivePreviewRootCapture.Plan.independent.acceptsFrame(captured: bounds,
                                                                     current: bounds.offsetBy(dx: 5000, dy: 0)))
    }

    @Test func `window group is not composited twice while isolated root extends to exactly one popup`() throws {
        let context = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let root = try #require(context.makeImage())
        let bounds = CGRect(x: -1000, y: -700, width: 600, height: 400)
        let popup = LivePreviewPopup.Window(windowID: 11, pid: 123,
                                            bounds: CGRect(x: -500, y: -750, width: 200, height: 500))
        let layers = [LivePreviewPopup.Layer(window: popup, image: root)]
        let fallback = LivePreviewRootCapture.render(root: root, bounds: bounds, layers: layers, plan: .independent)
        #expect(fallback.image === root && fallback.canvas == bounds)
        let isolated = LivePreviewRootCapture.render(root: root, bounds: bounds, layers: layers,
                                                     plan: .display(frame: displays[1], sourceRect: .zero))
        #expect(isolated.image !== root)
        #expect(isolated.canvas == bounds.union(popup.bounds))
        #expect(isolated.image.width == 960)
        #expect(isolated.image.height == Int(500.0 / 700.0 * 960.0))
    }
}
