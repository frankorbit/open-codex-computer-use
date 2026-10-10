//
//  LivePreviewTests.swift
//  {project}
//
//  Copyright © 2026 Today AI. All rights reserved.
//

import AppKit
@testable import OpenComputerUseKit
import Testing

struct LivePreviewTests {
    @Test @MainActor
    func framesResizeActualContentAndPreserveManualSize() throws {
        let panel = LivePreviewPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 240, height: 160)
        panel.maxSize = CGSize(width: 960, height: 720)
        defer { panel.finish() }
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        let wide = try previewImage(width: 960, height: 450)
        view.showFrame(wide)
        // AppKit 将窗口尺寸取整到显示像素，容许不超过一个点的舍入差。
        #expect(abs(view.bounds.width - 360) < 0.01)
        #expect(abs(view.bounds.height - 168.75) <= 1)

        // 模拟用户按比例放大；连续视频帧不能将尺寸恢复成默认值。
        panel.setContentSize(CGSize(width: 600, height: 281.25))
        let manualSize = view.bounds.size
        view.showFrame(wide)
        #expect(view.bounds.size == manualSize)
        #expect(abs(view.bounds.width - 600) < 0.01)
        #expect(abs(view.bounds.height - 281.25) <= 1)

        try view.showFrame(previewImage(width: 900, height: 960))
        #expect(abs(view.bounds.width - 600) < 0.01)
        #expect(abs(view.bounds.height - 640) < 0.01)
        #expect(panel.contentAspectRatio == CGSize(width: 900, height: 960))

        // 收起、切窗时清掉旧帧后，新首帧仍需重新同步比例。
        view.image = nil
        view.showFrame(wide)
        #expect(abs(view.bounds.height - 281.25) <= 1)
    }

    private func previewImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    @Test
    func optInOnly() {
        #expect(!livePreviewEnabled(environment: [:]))
        #expect(!livePreviewEnabled(environment: ["OPEN_COMPUTER_USE_LIVE_PREVIEW": "0"]))
        #expect(livePreviewEnabled(environment: ["OPEN_COMPUTER_USE_LIVE_PREVIEW": "1"]))
    }

    @Test
    func targetIdentityAndFiniteGeometryRequired() {
        let bounds = CGRect(x: 100, y: 80, width: 600, height: 400)
        #expect(LivePreviewTarget(pid: 1, windowID: 2, bounds: bounds) != nil)
        #expect(LivePreviewTarget(pid: 0, windowID: 2, bounds: bounds) == nil)
        #expect(LivePreviewTarget(pid: 1, windowID: nil, bounds: bounds) == nil)
        #expect(LivePreviewTarget(pid: 1, windowID: 2, bounds: .zero) == nil)
        #expect(LivePreviewTarget(pid: 1, windowID: 2, bounds: .infinite) == nil)
    }

    @Test
    func lateFramesCannotCrossWindowsOrLifecycle() throws {
        let first = try #require(LivePreviewTarget(
            pid: 1,
            windowID: 2,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400)
        ))
        let second = try #require(LivePreviewTarget(pid: 1, windowID: 3, bounds: first.bounds))
        var state = LivePreviewState()
        let selectedFirst = state.select(first)
        #expect(selectedFirst)
        let old = state.generation
        #expect(state.accepts(old))
        let selectedAgain = state.select(first)
        #expect(!selectedAgain)
        #expect(state.generation == old)
        let selectedSecond = state.select(second)
        #expect(selectedSecond)
        #expect(!state.accepts(old))
        let beforeHide = state.generation
        state.hide()
        #expect(!state.accepts(beforeHide))
        #expect(!state.accepts(state.generation))
        // 隐藏是当前轮的选择，下一次观察不能擅自重新弹出。
        let selectedHidden = state.select(first)
        #expect(selectedHidden)
        #expect(!state.accepts(state.generation))
        state.reopen()
        #expect(state.accepts(state.generation))
        let beforeReset = state.generation
        state.reset()
        #expect(!state.accepts(beforeReset))
        #expect(!state.accepts(state.generation))
    }

    @Test
    func resizeBackToObservedGeometryStillRetiresCapture() throws {
        let target = try #require(LivePreviewTarget(
            pid: 1,
            windowID: 2,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400)
        ))
        var state = LivePreviewState()
        _ = state.select(target)
        state.hide()
        // 隐藏时窗口变为 B，恢复后以 B 建流；目标记录仍可能是观察时的 A。
        state.reopen()
        let captureB = state.generation
        let restarted = state.select(target, forceGeometry: true)
        #expect(restarted)
        #expect(!state.accepts(captureB))
        #expect(state.accepts(state.generation))
    }

    @Test
    func cursorConvertsQuartzWindowToAppKitCoordinates() {
        let window = CGRect(x: -600, y: -200, width: 600, height: 400)
        #expect(livePreviewCursorPoint(tip: CGPoint(x: -300, y: 1000), window: window, primaryHeight: 1000)
            == CGPoint(x: 300, y: 200))
        #expect(livePreviewCursorPoint(tip: CGPoint(x: 500, y: 1000), window: window, primaryHeight: 1000) == nil)
    }
}
