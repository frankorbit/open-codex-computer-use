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
    func `frames resize actual content and preserve manual size`() throws {
        let panel = LivePreviewPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.finish() }
        let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        let wide = try previewImage(width: 960, height: 450)
        view.showFrame(wide)
        #expect(abs(view.bounds.width / view.bounds.height - 960.0 / 450) < 0.02)
        #expect(try #require(panel.visibleFrame).contains(panel.frame))

        // 连续帧保留用户缩放；换成竖屏时不再继承横屏宽度。
        panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.minY, width: 600, height: 281.25), display: false)
        let manualSize = view.bounds.size
        view.showFrame(wide)
        #expect(view.bounds.size == manualSize)
        try view.showFrame(previewImage(width: 300, height: 900))
        #expect(abs(view.bounds.width / view.bounds.height - 1.0 / 3) < 0.01)
        #expect(view.bounds.height <= 481)
        #expect(try #require(panel.visibleFrame).contains(panel.frame))
        #expect(panel.contentAspectRatio == CGSize(width: 300, height: 900))
        #expect(panel.isOpaque)
        #expect(panel.backgroundColor == .black)

        view.image = nil
        view.showFrame(wide)
        #expect(abs(view.bounds.width / view.bounds.height - 960.0 / 450) < 0.02)
        #expect(try #require(panel.visibleFrame).contains(panel.frame))
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
    func `opt in only`() {
        #expect(!livePreviewEnabled(environment: [:]))
        #expect(!livePreviewEnabled(environment: ["OPEN_COMPUTER_USE_LIVE_PREVIEW": "0"]))
        #expect(livePreviewEnabled(environment: ["OPEN_COMPUTER_USE_LIVE_PREVIEW": "1"]))
    }

    @Test
    func `target identity and finite geometry required`() {
        let bounds = CGRect(x: 100, y: 80, width: 600, height: 400)
        #expect(LivePreviewTarget(pid: 1, windowID: 2, bounds: bounds) != nil)
        #expect(LivePreviewTarget(pid: 0, windowID: 2, bounds: bounds) == nil)
        #expect(LivePreviewTarget(pid: 1, windowID: nil, bounds: bounds) == nil)
        #expect(LivePreviewTarget(pid: 1, windowID: 2, bounds: .zero) == nil)
        #expect(LivePreviewTarget(pid: 1, windowID: 2, bounds: .infinite) == nil)
    }

    @Test
    func `late frames cannot cross windows or lifecycle`() throws {
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
    func `resize back to observed geometry still retires capture`() throws {
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
    func `cursor converts quartz window to app kit coordinates`() {
        let window = CGRect(x: -600, y: -200, width: 600, height: 400)
        #expect(livePreviewCursorPoint(tip: CGPoint(x: -300, y: 1000), window: window, primaryHeight: 1000)
            == CGPoint(x: 300, y: 200))
        #expect(livePreviewCursorPoint(tip: CGPoint(x: 500, y: 1000), window: window, primaryHeight: 1000) == nil)
    }
}
