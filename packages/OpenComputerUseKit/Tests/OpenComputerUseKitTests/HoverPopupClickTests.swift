import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import Testing

struct HoverPopupClickTests {
    private let token = "00000000-0000-0000-0000-000000000001"

    private func snapshot(pid: pid_t = 11, windowID: CGWindowID = 1) -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(
                name: "fixture",
                bundleIdentifier: "test.popup",
                pid: pid,
                runningApplication: .current
            ),
            windowTitle: "fixture",
            windowBounds: CGRect(x: -500, y: 100, width: 800, height: 600),
            targetWindowID: windowID,
            targetWindowLayer: 0,
            screenshotData: nil,
            mode: .accessibility,
            treeLines: [],
            focusedSummary: nil,
            focusedElement: nil,
            selectedText: nil,
            windowElement: nil,
            elements: [:]
        )
    }

    private func popup() -> HoverPopupObservation {
        HoverPopupObservation(
            token: token,
            windowID: 2,
            pid: 11,
            bounds: CGRect(x: -300, y: 200, width: 200, height: 100),
            imageData: Data([1]),
            pixelSize: CGSize(width: 400, height: 200)
        )
    }

    @Test func `popup coordinates use their own retina frame`() throws {
        var cache = HoverPopupCache()
        cache.record([popup()], snapshot: snapshot(), now: 10)
        let lease = try cache.take(token)
        #expect(try lease.globalPoint(for: CGPoint(x: 100, y: 100), snapshot: snapshot(), now: 11)
            == CGPoint(x: -250, y: 250))
        for point in [
            CGPoint(x: -1, y: 0),
            CGPoint(x: 400, y: 0),
            CGPoint(x: 0, y: 200),
            CGPoint(x: CGFloat.infinity, y: 0)
        ] {
            #expect(throws: (any Error).self) { try lease.globalPoint(for: point, snapshot: snapshot(), now: 11) }
        }
    }

    @Test func `token is consumed on success and unknown token attempt`() throws {
        var cache = HoverPopupCache()
        cache.record([popup()], snapshot: snapshot(), now: 10)
        _ = try cache.take(token)
        #expect(throws: (any Error).self) { try cache.take(token) }
        cache.record([popup()], snapshot: snapshot(), now: 10)
        #expect(throws: (any Error).self) { try cache.take("other") }
        #expect(throws: (any Error).self) { try cache.take(token) }
        cache.record([popup()], snapshot: snapshot(), now: 10)
        cache.clear()
        #expect(throws: (any Error).self) { try cache.take(token) }
    }

    @Test func `expired or different context cannot use popup`() throws {
        let lease = HoverPopupLease(popup: popup(), rootWindowID: 1, rootBounds: snapshot().windowBounds, createdAt: 10)
        for now in [9.0, 40.1] {
            #expect(throws: (any Error).self) { try lease.globalPoint(for: .zero, snapshot: snapshot(), now: now) }
        }
        for state in [snapshot(pid: 12), snapshot(windowID: 3)] {
            #expect(throws: (any Error).self) { try lease.globalPoint(for: .zero, snapshot: state, now: 11) }
        }
    }

    @Test func `request rejects wrong coordinate and action contracts`() throws {
        let base: [String: Any] = ["popup_token": token, "x": 1, "y": 2]
        #expect(try HoverPopupClickRequest(arguments: base).point == CGPoint(x: 1, y: 2))
        #expect(try HoverPopupClickRequest(arguments: base).method == .global)
        #expect(try HoverPopupClickRequest(arguments: base.merging(["click_method": "sky_click"]) { _, new in
            new
        }).method == .skyClick)
        for override: [String: Any] in [
            ["popup_token": "invalid"], ["popup_token": 1], ["element_index": "3"],
            ["click_method": "auto"], ["click_method": "app_post"], ["click_method": "accessibility"],
            ["click_method": true], ["mouse_button": "right"], ["click_count": 2],
            ["click_count": Double.infinity], ["click_count": true], ["x": true],
            ["y": Double.nan], ["x": -1], ["x": "2"]
        ] {
            #expect(throws: (any Error).self) {
                try HoverPopupClickRequest(arguments: base.merging(override) { _, new in new })
            }
        }
    }

    @Test func `validation failure never posts and read back failure never replays`() throws {
        var posts = 0
        #expect(throws: (any Error).self) {
            try dispatchPopupClick(
                validate: { throw ComputerUseError.message("changed") },
                submit: { posts += 1 },
                readBack: {}
            )
        }
        #expect(posts == 0)
        do {
            try dispatchPopupClick(
                validate: {},
                submit: { posts += 1 },
                readBack: { throw ComputerUseError.message("capture failed") }
            )
            Issue.record("Expected unknown effect")
        } catch {
            #expect(error.localizedDescription.contains("input may have occurred"))
        }
        #expect(posts == 1)
    }

    @Test func `same PID does not permit clicking another receiving window`() throws {
        let bounds = popup().bounds
        let windows: [[String: Any]] = [[
            kCGWindowNumber as String: 2, kCGWindowOwnerPID as String: 11,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowAlpha as String: 1, kCGWindowIsOnscreen as String: true
        ]]
        for receiver: CGWindowID? in [nil, 1, 3] {
            #expect(throws: (any Error).self) {
                try validateCoordinateWindow(
                    windowID: 2,
                    pid: 11,
                    bounds: bounds,
                    point: CGPoint(x: -250, y: 250),
                    windows: windows,
                    requireUnoccludedPoint: true,
                    spacesForWindow: { _ in nil },
                    mouseReceiver: { _ in receiver }
                )
            }
        }
    }
}
