import AppKit
@testable import OpenComputerUseKit
import Testing

struct LivePreviewLayoutTests {
    @Test(arguments: [CGSize(width: 300, height: 900), CGSize(width: 1600, height: 200),
                      CGSize(width: 300, height: 3000)])
    func `source changes stay on small and negative origin screens`(aspect: CGSize) {
        for screen in [CGRect(x: 0, y: 60, width: 1280, height: 680),
                       CGRect(x: -800, y: -400, width: 800, height: 500),
                       CGRect(x: 0, y: 0, width: 320, height: 240)] {
            let current = CGRect(x: screen.maxX - 360, y: screen.minY + 12, width: 360, height: 170)
            let frame = LivePreviewLayout.sourceChangeFrame(aspect: aspect, current: current, visibleFrame: screen)
            #expect(screen.contains(frame))
            #expect(frame.height <= 480)
            #expect(abs(frame.width / frame.height - aspect.width / aspect.height) < 0.0001)
            let maximum = LivePreviewLayout.maximumSize(aspect: aspect, visibleFrame: screen)
            let minimum = LivePreviewLayout.minimumSize(aspect: aspect, maximum: maximum)
            #expect(minimum.width <= maximum.width && minimum.height <= maximum.height)
            #expect(frame.width >= minimum.width - 0.001 && frame.height >= minimum.height - 0.001)
        }
    }

    @Test func `disconnected display frame moves into remaining screen`() {
        let screen = CGRect(x: 0, y: 80, width: 800, height: 500)
        let result = LivePreviewLayout.contained(CGRect(x: -1500, y: -700, width: 600, height: 1200),
                                                 in: LivePreviewLayout.available(in: screen))
        #expect(screen.contains(result))
        #expect(abs(result.width / result.height - 0.5) < 0.0001)
        let duringResize = LivePreviewResizeEdge.right.resizedFrame(
            from: CGRect(x: 2000, y: 0, width: 300, height: 200), delta: CGSize(width: 100, height: 0),
            minimum: CGSize(width: 240, height: 160), maximum: CGSize(width: 600, height: 400), visibleFrame: screen
        )
        #expect(screen.contains(duringResize))
        #expect(duringResize.width > 0 && duringResize.height > 0)
    }

    @Test(arguments: LivePreviewResizeEdge.allCases)
    func `edges match cursors and resize without moving opposite anchor`(edge: LivePreviewResizeEdge) {
        let frame = CGRect(x: 300, y: 250, width: 300, height: 200)
        let hit = edge.hitRect(in: CGRect(origin: .zero, size: frame.size))
        #expect(LivePreviewResizeEdge.hit(at: CGPoint(x: hit.midX, y: hit.midY),
                                          in: CGRect(origin: .zero, size: frame.size)) == edge)
        let result = edge.resizedFrame(
            from: frame,
            delta: CGSize(width: edge.horizontal * 30, height: edge.vertical * 20),
            minimum: CGSize(width: 150, height: 100),
            maximum: CGSize(width: 900, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )
        #expect(abs(result.width / result.height - 1.5) < 0.0001)
        #expect(result.width > frame.width)
        if edge.horizontal > 0 { #expect(result.minX == frame.minX) }
        if edge.horizontal < 0 { #expect(abs(result.maxX - frame.maxX) < 0.001) }
        if edge.vertical > 0 { #expect(result.minY == frame.minY) }
        if edge.vertical < 0 { #expect(abs(result.maxY - frame.maxY) < 0.001) }
    }

    @Test(arguments: LivePreviewResizeEdge.allCases)
    func `dragging past screen or minimum is bounded`(edge: LivePreviewResizeEdge) {
        let screen = CGRect(x: -800, y: 60, width: 800, height: 600)
        let frame = CGRect(x: -600, y: 250, width: 240, height: 160)
        for amount: CGFloat in [-10000, 10000] {
            let result = edge.resizedFrame(from: frame,
                                           delta: CGSize(
                                               width: amount * edge.horizontal,
                                               height: amount * edge.vertical
                                           ),
                                           minimum: CGSize(width: 180, height: 120), maximum: CGSize(
                                               width: 600,
                                               height: 400
                                           ),
                                           visibleFrame: screen)
            #expect(screen.contains(result))
            #expect(result.width >= 179.99 && result.height >= 119.99)
            #expect(abs(result.width / result.height - 1.5) < 0.0001)
        }
    }

    @Test @MainActor func `resize gesture uses production mouse handlers`() throws {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        var hideRequested = false
        let panel = LivePreviewPanel.make(view: view, inputActive: false) { hideRequested = true }
        defer { panel.finish() }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isMovableByWindowBackground)
        panel.performClose(nil)
        #expect(hideRequested)
        panel.showSource(size: CGSize(width: 600, height: 400))
        let original = panel.frame
        let hit = LivePreviewResizeEdge.right.hitRect(in: view.bounds)
        let start = view.convert(CGPoint(x: hit.midX, y: hit.midY), to: nil)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: 1))
        }
        try view.mouseDown(with: event(.leftMouseDown, at: start))
        #expect(panel.userInteractionActive)
        try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: start.x - 40, y: start.y)))
        try view.mouseUp(with: event(.leftMouseUp, at: start))
        #expect(!panel.userInteractionActive)
        #expect(panel.frame.width < original.width)
        #expect(abs(panel.frame.width / panel.frame.height - 1.5) < 0.02)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)

        let edge = LivePreviewResizeEdge.right.hitRect(in: view.bounds)
        try view.mouseDown(with: event(.leftMouseDown, at: view.convert(CGPoint(x: edge.midX, y: edge.midY), to: nil)))
        #expect(panel.userInteractionActive)
        view.cancelInteraction()
        #expect(!panel.userInteractionActive)
        let cancelledFrame = panel.frame
        try view.mouseDragged(with: event(.leftMouseDragged, at: .zero))
        #expect(panel.frame == cancelledFrame)

        panel.ignoresMouseEvents = true
        try view.mouseDown(with: event(.leftMouseDown, at: start))
        #expect(!panel.userInteractionActive)
    }

    @Test @MainActor func `pixels fill bounds and transparent frames clear previous opaque pixels`() throws {
        let source = try #require(CGContext(data: nil, width: 96, height: 45, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 96, height: 45))
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 169))
        view.image = try #require(source.makeImage())
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 169,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                                   bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        view.draw(view.bounds)
        let center = try #require(bitmap.colorAt(x: 180, y: 84)?.usingColorSpace(.deviceRGB))
        for pixelY in [0, 84, 168] {
            for pixelX in [0, 180, 359] {
                let color = try #require(bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB))
                #expect(color.greenComponent > 0.9)
                #expect(abs(color.greenComponent - center.greenComponent) < 0.001)
                #expect(color.alphaComponent > 0.99)
            }
        }
        source.clear(CGRect(x: 0, y: 0, width: 96, height: 45))
        view.image = try #require(source.makeImage())
        view.draw(view.bounds)
        let matte = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(matte.alphaComponent == 0)
        #expect(matte.redComponent == 0 && matte.greenComponent == 0 && matte.blueComponent == 0)

        // 加载提示出现后仍须清掉底衬；真实黑色像素不能被当作透明色抠除。
        view.image = nil
        view.draw(view.bounds)
        #expect(try #require(bitmap.colorAt(x: 30, y: 30)).alphaComponent > 0.9)
        source.setFillColor(CGColor(gray: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 48, height: 45))
        view.image = try #require(source.makeImage())
        view.draw(view.bounds)
        let black = try #require(bitmap.colorAt(x: 30, y: 30)?.usingColorSpace(.deviceRGB))
        #expect(black.alphaComponent > 0.99 && black.redComponent == 0)
        #expect(try #require(bitmap.colorAt(x: 300, y: 30)).alphaComponent == 0)
    }
}
