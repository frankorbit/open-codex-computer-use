import AppKit
@testable import OpenComputerUseKit
import Testing

struct LivePreviewControlsTests {
    @Test @MainActor func `hide control follows root inside extended canvas and resize`() throws {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 720, height: 690))
        let panel = LivePreviewPanel.make(view: view, inputActive: false, onHide: {})
        defer { panel.finish() }
        #expect(try #require(panel.standardWindowButton(.closeButton)).isHidden)
        let root = CGRect(x: -500, y: 100, width: 720, height: 570)
        let canvas = CGRect(x: -580, y: 20, width: 800, height: 690)
        view.controls.anchor(root: root, canvas: canvas)
        for size in [CGSize(width: 720, height: 690), CGSize(width: 360, height: 345)] {
            view.controls.frame = CGRect(origin: .zero, size: size)
            view.controls.layoutSubtreeIfNeeded()
            let button = view.controls.hideButton
            #expect(!button.isHidden)
            let expectedTop = size.height * (canvas.maxY - root.minY) / canvas.height
            #expect(abs(button.frame.maxY - (expectedTop - 10)) < 0.01)
            #expect(abs(button.frame.minX - (80 * size.width / canvas.width + 10)) < 0.01)
            #expect(button.frame.size == CGSize(width: 24, height: 24))
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
        view.controls.hideButton.performClick(nil)
        #expect(hides == 1)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.userInteractionActive)
        panel.ignoresMouseEvents = true
        view.controls.hideButton.performClick(nil)
        #expect(hides == 1)
        let button = view.controls.hideButton.frame
        #expect(view.controls.hitTest(CGPoint(x: button.midX, y: button.midY)) == nil)
        view.controls.frame = CGRect(x: 0, y: 0, width: 30, height: 200)
        view.controls.layoutSubtreeIfNeeded()
        #expect(!view.controls.hideButton.isHidden)
        #expect(view.controls.bounds.contains(view.controls.hideButton.frame))
    }
}
