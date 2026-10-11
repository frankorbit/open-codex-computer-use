import AppKit
@testable import OpenComputerUseKit
import Testing

@MainActor
struct LivePreviewCursorAccessTests {
    private enum Failure: Error { case unavailable }

    @Test func `hover restores missing false and existing true properties`() {
        for original: CFTypeRef? in [nil, kCFBooleanFalse, kCFBooleanTrue] {
            var current = original
            var reads = 0
            var writes = 0
            let access = LivePreviewCursorAccess(backend: .init(read: {
                reads += 1
                return current
            }, write: {
                writes += 1
                current = $0
            }))
            access.begin()
            access.begin()
            #expect(access.isActive)
            #expect(current as? Bool == true)
            #expect(reads == 1 && writes == 1)
            access.end()
            access.end()
            #expect(!access.isActive)
            #expect(current as? Bool == original as? Bool)
            #expect(writes == 2)
        }
    }

    @Test func `failed reads do not mutate connection and failed restores can retry`() {
        var writes = 0
        let unavailable = LivePreviewCursorAccess(backend: .init(read: {
            throw Failure.unavailable
        }, write: { _ in writes += 1 }))
        unavailable.begin()
        unavailable.end()
        #expect(writes == 0 && !unavailable.isActive)

        var current: CFTypeRef? = kCFBooleanFalse
        var rejectRestore = true
        let access = LivePreviewCursorAccess(backend: .init(read: { current }, write: {
            if $0 as? Bool == false, rejectRestore { throw Failure.unavailable }
            current = $0
        }))
        access.begin()
        access.end()
        #expect(access.isActive)
        #expect(current as? Bool == true)
        rejectRestore = false
        access.end()
        #expect(!access.isActive)
        #expect(current as? Bool == false)
    }

    @Test func `nonactivating panel delivers move and enter exit tracking`() {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        let panel = LivePreviewPanel.make(view: view, inputActive: false, onHide: {})
        defer { panel.finish() }
        view.updateTrackingAreas()
        #expect(panel.acceptsMouseMovedEvents)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        let options = view.trackingAreas.first?.options
        #expect(options?.contains([.activeAlways, .mouseMoved, .mouseEnteredAndExited]) == true)
        #expect(options?.contains(.cursorUpdate) == false)
    }
}
