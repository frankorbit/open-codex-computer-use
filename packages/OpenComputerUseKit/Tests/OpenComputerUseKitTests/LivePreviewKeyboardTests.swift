import AppKit
@testable import OpenComputerUseKit
import ScreenCaptureKit
import Testing

@MainActor
struct LivePreviewKeyboardTests {
    @Test func `keyboard badge clears stale cursor without changing captured image`() throws {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        let context = try #require(CGContext(
            data: nil, width: 360, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        view.image = image
        view.cursorPoint = CGPoint(x: 100, y: 100)
        view.keyboardInputVisible = true
        #expect(view.cursorPoint == nil && view.cursorState == nil)
        #expect(view.image === image)
        #expect(view.accessibilityValue() as? String == "键盘输入中")
        view.keyboardInputVisible = false
        #expect(view.cursorPoint == nil)
        #expect(view.image === image)
    }

    @Test func `badge paints locally without replacing the image or covering the result area`() throws {
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 230, height: 408))
        let context = try #require(CGContext(
            data: nil, width: 230, height: 408, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(view.bounds)
        let source = try #require(context.makeImage())
        view.image = source
        view.keyboardInputVisible = true
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(view.bounds)
        let rendered = try NSBitmapImageRep(cgImage: #require(context.makeImage()))
        let original = NSBitmapImageRep(cgImage: source)
        // 顶部提示被绘制，内容区域与源图完全一致；模型仍拿到原始 image。
        #expect(rendered.colorAt(x: 70, y: 23) != original.colorAt(x: 70, y: 23))
        #expect(rendered.colorAt(x: 115, y: 150) == original.colorAt(x: 115, y: 150))
        #expect(view.image === source)
    }

    @Test func `continuous keys cancel old badge timer and pointer input clears it immediately`() async throws {
        let state = LivePreviewKeyboardPresentation(badgeLinger: .milliseconds(20), onChange: {})
        state.beginInput(keyboard: true)
        state.endKeyboardInput()
        state.beginInput(keyboard: true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(state.isVisible)
        state.endKeyboardInput()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!state.isVisible)
        state.beginInput(keyboard: true)
        state.setFocusActive(true)
        state.beginInput(keyboard: false)
        #expect(!state.isVisible && !state.isHoldingFrames)
    }

    @Test func `focus transition releases latest frame and long typing has bounded hold`() async throws {
        let state = LivePreviewKeyboardPresentation(
            maximumHold: .milliseconds(20), settle: .milliseconds(20), onChange: {}
        )
        state.setFocusActive(true)
        #expect(state.isHoldingFrames)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!state.isHoldingFrames)
        state.setFocusActive(false)
        #expect(state.isHoldingFrames)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!state.isHoldingFrames)
    }

    @Test func `new key cancels previous settle and reset cancels all late presentation callbacks`() async throws {
        var callbacks = 0
        let state = LivePreviewKeyboardPresentation(
            maximumHold: .seconds(1), settle: .milliseconds(20), badgeLinger: .milliseconds(20),
            onChange: { callbacks += 1 }
        )
        state.beginInput(keyboard: true)
        state.setFocusActive(false)
        state.setFocusActive(true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(state.isHoldingFrames)
        state.endKeyboardInput()
        state.reset()
        let afterReset = callbacks
        try await Task.sleep(for: .milliseconds(80))
        #expect(callbacks == afterReset)
        #expect(!state.isVisible && !state.isHoldingFrames)
    }

    @Test func `continuous short keys cannot renew the frame hold deadline`() async throws {
        var changes = 0
        let state = LivePreviewKeyboardPresentation(
            maximumHold: .milliseconds(80), settle: .seconds(1), onChange: { changes += 1 }
        )
        defer { state.reset() }
        // 按键间隔短于稳定等待；旧实现会一直续期，整个循环只通知首次暂停。
        for _ in 0 ..< 20 {
            state.setFocusActive(true)
            try await Task.sleep(for: .milliseconds(10))
            state.setFocusActive(false)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(changes >= 3)
        // 连续事件结束后，最后一轮也必须在硬上限内恢复，不能等满 settle。
        try await Task.sleep(for: .milliseconds(150))
        #expect(!state.isHoldingFrames)
    }

    @Test func `focus release cannot extend an existing hard deadline`() async throws {
        let state = LivePreviewKeyboardPresentation(
            maximumHold: .milliseconds(80), settle: .seconds(1), onChange: {}
        )
        defer { state.reset() }
        state.setFocusActive(true)
        try await Task.sleep(for: .milliseconds(30))
        state.setFocusActive(false)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!state.isHoldingFrames)
    }

    @Test func `quiet focus release still restores frames before the hard deadline`() async throws {
        let state = LivePreviewKeyboardPresentation(
            maximumHold: .seconds(1), settle: .milliseconds(20), onChange: {}
        )
        defer { state.reset() }
        state.setFocusActive(true)
        state.setFocusActive(false)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!state.isHoldingFrames)
    }

    @Test func `expired deadline releases frames even before its queued task can run`() {
        var changes = 0
        let state = LivePreviewKeyboardPresentation(maximumHold: .zero, onChange: { changes += 1 })
        defer { state.reset() }
        state.setFocusActive(true)
        #expect(changes == 1)
        // 同一段 MainActor 同步执行不让计时任务运行，下一事件仍须先放行旧帧。
        state.setFocusActive(true)
        #expect(changes == 3)
        #expect(state.isHoldingFrames)
    }

    @Test func `temporary capture start differs from real blank suspension and stop`() {
        #expect(PreviewFrameSink.disposition(for: SCFrameStatus.started.rawValue) == .transient)
        #expect(PreviewFrameSink.disposition(for: SCFrameStatus.complete.rawValue) == .decode)
        #expect(PreviewFrameSink.disposition(for: SCFrameStatus.idle.rawValue) == .ignore)
        let unavailable = [SCFrameStatus.blank.rawValue, SCFrameStatus.suspended.rawValue,
                           SCFrameStatus.stopped.rawValue, -1]
        for status in unavailable {
            #expect(PreviewFrameSink.disposition(for: status) == .unavailable)
        }
    }

    @Test func `transient grace expires once and recovered or replaced captures cancel late clearing`() async throws {
        var clears = 0
        let grace = LivePreviewFrameGrace(duration: .milliseconds(20)) { clears += 1 }
        grace.waitForCompleteFrame()
        grace.waitForCompleteFrame()
        try await Task.sleep(for: .milliseconds(80))
        #expect(clears == 1)
        grace.waitForCompleteFrame()
        grace.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(clears == 1)
        // 旧回调取消后，新流仍可独立进入有界缺帧等待。
        grace.waitForCompleteFrame()
        try await Task.sleep(for: .milliseconds(80))
        #expect(clears == 2)
    }
}
