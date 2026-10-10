//
//  LivePreviewTests.swift
//  {project}
//
//  Copyright © 2026 Today AI. All rights reserved.
//

import CoreGraphics
@testable import OpenComputerUseKit
import Testing

struct LivePreviewTests {
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
