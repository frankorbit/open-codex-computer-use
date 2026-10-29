import AppKit
@testable import OpenComputerUseKit
import Testing

struct LivePreviewControlsTests {
    @Test @MainActor func `hide button keeps contrast on light and dark content`() throws {
        let button = LivePreviewHideButton(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for background in [NSColor.white, .black] {
            background.setFill()
            button.bounds.fill()
            button.draw(button.bounds)
            let glyph = try #require(bitmap.colorAt(x: 14, y: 14)?.usingColorSpace(.deviceRGB))
            let backing = try #require(bitmap.colorAt(x: 7, y: 14)?.usingColorSpace(.deviceRGB))
            #expect(glyph.redComponent > 0.9)
            #expect(backing.redComponent < 0.25)
            #expect(glyph.alphaComponent == 1 && backing.alphaComponent == 1)
        }
    }

    @Test @MainActor func `preview enter and move reveal controls only inside its bounds`() throws {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        let panel = LivePreviewPanel.make(view: view, inputActive: false, onHide: {})
        defer { panel.finish() }
        panel.orderFrontRegardless()
        view.controls.layoutSubtreeIfNeeded()
        #expect(view.controls.hideButton.isHidden)
        let inside = view.convert(CGPoint(x: 180, y: 120), to: nil)
        let entered = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: inside, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        view.mouseEntered(with: entered)
        #expect(!view.controls.hideButton.isHidden)
        let button = view.controls.hideButton.frame
        let onButton = view.convert(CGPoint(x: button.midX, y: button.midY), to: nil)
        for (point, visible) in [(onButton, true), (CGPoint(x: -20, y: -20), false)] {
            let moved = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
            view.mouseMoved(with: moved)
            #expect(view.controls.hideButton.isHidden == !visible)
        }
        panel.ignoresMouseEvents = true
        view.mouseEntered(with: entered)
        #expect(view.controls.hideButton.isHidden)
    }

    @Test @MainActor func `hide control follows root inside extended canvas and resize`() throws {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 720, height: 690))
        let panel = LivePreviewPanel.make(view: view, inputActive: false, onHide: {})
        defer { panel.finish() }
        #expect(try #require(panel.standardWindowButton(.closeButton)).isHidden)
        let root = CGRect(x: -500, y: 100, width: 720, height: 570)
        let canvas = CGRect(x: -580, y: 20, width: 800, height: 690)
        view.controls.anchor(root: root, canvas: canvas)
        view.controls.updatePointerPresence(true)
        for size in [CGSize(width: 720, height: 690), CGSize(width: 360, height: 345)] {
            view.controls.frame = CGRect(origin: .zero, size: size)
            view.controls.layoutSubtreeIfNeeded()
            let button = view.controls.hideButton
            #expect(!button.isHidden)
            let expectedTop = size.height * (canvas.maxY - root.minY) / canvas.height
            #expect(abs(button.frame.maxY - (expectedTop - 10)) < 0.01)
            #expect(abs(button.frame.minX - (80 * size.width / canvas.width + 10)) < 0.01)
            #expect(button.frame.size == CGSize(width: 28, height: 28))
            #expect(view.controls.hitTest(CGPoint(x: button.frame.midX, y: button.frame.midY)) === button)
            #expect(view.controls.hitTest(CGPoint(x: size.width - 1, y: size.height / 2)) == nil)
        }
        view.image = nil
        view.controls.layoutSubtreeIfNeeded()
        #expect(view.controls.hideButton.frame.maxY == view.controls.bounds.maxY - 10)
    }

    @Test @MainActor func `hide control only hides preview and respects input passthrough`() {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        var hides = 0
        let panel = LivePreviewPanel.make(view: view, inputActive: false) { hides += 1 }
        defer { panel.finish() }
        view.controls.layoutSubtreeIfNeeded()
        #expect(view.controls.hideButton.isHidden)
        view.controls.hideButton.performClick(nil)
        #expect(hides == 0)
        view.controls.updatePointerPresence(true)
        view.controls.hideButton.performClick(nil)
        #expect(hides == 1)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.userInteractionActive)
        panel.ignoresMouseEvents = true
        view.controls.updatePointerPresence(true)
        #expect(view.controls.hideButton.isHidden)
        view.controls.hideButton.performClick(nil)
        #expect(hides == 1)
        let button = view.controls.hideButton.frame
        #expect(view.controls.hitTest(CGPoint(x: button.midX, y: button.midY)) == nil)
        panel.ignoresMouseEvents = false
        view.controls.updatePointerPresence(true)
        view.controls.frame = CGRect(x: 0, y: 0, width: 30, height: 200)
        view.controls.layoutSubtreeIfNeeded()
        #expect(!view.controls.hideButton.isHidden)
        #expect(view.controls.bounds.contains(view.controls.hideButton.frame))
    }

    @Test @MainActor func `hover visibility survives resize but clears on exit and teardown`() throws {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        let panel = LivePreviewPanel.make(view: view, inputActive: false, onHide: {})
        defer { panel.finish() }
        view.controls.layoutSubtreeIfNeeded()
        let point = CGPoint(x: view.controls.hideButton.frame.midX, y: view.controls.hideButton.frame.midY)
        #expect(view.controls.hitTest(point) == nil)
        view.controls.updatePointerPresence(true)
        #expect(!view.controls.hideButton.isHidden)
        view.controls.frame.size = CGSize(width: 500, height: 300)
        view.controls.layoutSubtreeIfNeeded()
        #expect(!view.controls.hideButton.isHidden)
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        view.mouseExited(with: event)
        #expect(view.controls.hideButton.isHidden)
        #expect(view.controls.hitTest(point) == nil)
        view.controls.updatePointerPresence(true)
        panel.orderOut(nil)
        #expect(view.controls.hideButton.isHidden)
        view.controls.updatePointerPresence(true)
        view.cancelInteraction()
        #expect(view.controls.hideButton.isHidden)
        view.controls.frame.size = CGSize(width: 500, height: 300)
        view.controls.layoutSubtreeIfNeeded()
        #expect(view.controls.hideButton.isHidden)
    }
}
