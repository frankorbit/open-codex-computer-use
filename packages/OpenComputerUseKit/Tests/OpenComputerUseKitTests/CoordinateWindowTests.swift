import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class CoordinateWindowTests: XCTestCase {
    private let bounds = CGRect(x: -900, y: 120, width: 800, height: 600)
    private let point = CGPoint(x: -600, y: 400)

    private func window(id: Int = 42, pid: Int = 1234, rect: CGRect? = nil, visible: Bool = true,
                        alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: (rect ?? bounds).dictionaryRepresentation,
         kCGWindowIsOnscreen as String: NSNumber(value: visible), kCGWindowAlpha as String: NSNumber(value: alpha)]
    }

    private func validate(
        _ windows: [[String: Any]],
        global: Bool = false,
        at location: CGPoint? = nil,
        receiver: CGWindowID? = 42,
        spaces: @escaping (CGWindowID) -> [UInt64]? = { _ in [1] }
    ) throws {
        try validateCoordinateWindow(windowID: 42, pid: 1234, bounds: bounds, point: location ?? point,
                                     windows: windows, requireUnoccludedPoint: global, spacesForWindow: spaces,
                                     mouseReceiver: { _ in receiver }, backgroundWindows: { _ in
                                         // 此 helper 的数组是显式构造的有序测试样本，生产不使用 all 数组推断。
                                         let target = windows
                                             .firstIndex {
                                                 ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == 42
                                             } ?? 0
                                         return .onScreenAbove(Array(windows.prefix(target)))
                                     })
    }

    func testValidWindowDoesNotNeedAX() throws {
        try validate([window()])
    }

    func testForegroundPreflightCanRaiseCoveredWindowButFinalCheckStillRejectsCover() throws {
        let covered = [window(id: 43), window()]
        try validateCoordinateWindow(
            windowID: 42, pid: 1234, bounds: bounds, point: point, windows: covered,
            requireUnoccludedPoint: false, identityOnly: true, spacesForWindow: { _ in [1] }
        )
        XCTAssertThrowsError(try validate(covered, global: true, receiver: 43))
        try validate([window(), window(id: 43)], global: true)
        XCTAssertThrowsError(try validateCoordinateWindow(
            windowID: 42, pid: 1234, bounds: bounds, point: point,
            windows: [window(pid: 4321)], requireUnoccludedPoint: false, identityOnly: true,
            spacesForWindow: { _ in [1] }
        ))
    }

    func testMissingReusedOrTransparentWindowRejects() {
        for windows in [[], [window(id: 43)], [window(pid: 4321)], [window(alpha: 0)]] {
            XCTAssertThrowsError(try validate(windows))
        }
    }

    func testMovedAndResizedWindowsRejectOldCoordinates() {
        XCTAssertThrowsError(try validate([window(rect: bounds.offsetBy(dx: 1, dy: 0))]))
        XCTAssertThrowsError(try validate([window(rect: CGRect(x: -900, y: 120, width: 801, height: 600))]))
    }

    func testOutsideAndNonfinitePointsReject() {
        for location in [
            CGPoint(x: -901, y: 400),
            CGPoint(x: CGFloat.nan, y: 400),
            CGPoint(x: -600, y: CGFloat.infinity)
        ] {
            XCTAssertThrowsError(try validate([window()], at: location))
        }
    }

    func testSameProcessPopupCoveringPointRejects() {
        XCTAssertThrowsError(try validate([window(id: 43), window()]))
    }

    func testOtherAppCoverAllowsWindowDirectedButNotGlobalInput() throws {
        let windows = [window(id: 43, pid: 4321), window()]
        try validate(windows)
        XCTAssertThrowsError(try validate(windows, global: true, receiver: 43))
    }

    func testInvisibleNonoverlappingAndBehindWindowsDoNotBlock() throws {
        try validate([window(id: 43, visible: false), window()])
        try validate([window(id: 43, alpha: 0), window()])
        try validate([window(id: 43, rect: bounds.offsetBy(dx: 1000, dy: 0)), window()])
        try validate([window(), window(id: 43)])
    }

    func testOwnCursorOverlayDoesNotBlock() throws {
        try validate([window(id: 43, pid: Int(getpid())), window()], global: true)
    }

    func testClickThroughDockRectangleDoesNotBlockActualTargetReceiver() throws {
        var overlay = window(id: 56, pid: 800, rect: CGRect(x: -1000, y: 0, width: 2512, height: 982))
        overlay[kCGWindowLayer as String] = NSNumber(value: 20)
        // Dock 全屏矩形仍在列表里；真正接收 mouseDown 的是目标窗口。
        try validate([overlay, window()], global: true, receiver: 42, spaces: { _ in nil })
        XCTAssertThrowsError(try validate([overlay, window()], global: true, receiver: 56))
    }

    func testUnknownSiblingAndHelperReceiversRejectBeforeInput() {
        for receiver: CGWindowID? in [nil, 43, 99] {
            XCTAssertThrowsError(try validate([window(id: 99, pid: Int(getpid())), window(id: 43), window()],
                                              global: true, receiver: receiver))
        }
    }

    func testReceiverMatchCannotBypassTargetIdentityOrGeometry() {
        XCTAssertThrowsError(try validate([window(pid: 9876)], global: true))
        XCTAssertThrowsError(try validate([window(rect: bounds.offsetBy(dx: 1, dy: 0))], global: true))
    }

    func testReceiverValidationGatesForegroundSubmissionWithoutRetry() throws {
        for receiver: CGWindowID? in [42, 56, nil] {
            var inputs = 0
            var checks = 0
            let click = {
                try dispatchForegroundClick(
                    validateTarget: {}, prepare: {},
                    validateReceiver: {
                        checks += 1
                        try self.validate(
                            [self.window(id: 56, pid: 800), self.window()],
                            global: true,
                            receiver: receiver
                        )
                    },
                    submit: { inputs += 1 }
                )
            }
            if receiver == 42 { try click() } else { XCTAssertThrowsError(try click()) }
            XCTAssertEqual(checks, 1)
            XCTAssertEqual(inputs, receiver == 42 ? 1 : 0)
        }
    }

    func testDifferentSpacesAtSameCoordinatesDoNotObstruct() throws {
        try validate([window(id: 43), window()], spaces: { $0 == 42 ? [1] : [2] })
        try validate([window(id: 43, pid: 4321), window()], global: true, spaces: { $0 == 42 ? [1] : [2] })
    }

    func testSharedSpaceAndUnknownSpaceStillRejectObstruction() {
        XCTAssertThrowsError(try validate([window(id: 43), window()], spaces: { $0 == 42 ? [1, 2] : [2, 3] }))
        XCTAssertThrowsError(try validate([window(id: 43), window()], spaces: { _ in nil }))
    }

    func testOffscreenWindowSupportsDirectedInputButNotGlobal() throws {
        try validate([window(visible: false)])
        XCTAssertThrowsError(try validate([window(visible: false)], global: true))
    }

    func testPIDOnlyMouseAllowsUnavailableAXButRejectsKnownWrongWindow() throws {
        try validateCoordinateAppPostReceiver(focusedWindowMatches: true)
        try validateCoordinateAppPostReceiver(focusedWindowMatches: nil)
        XCTAssertThrowsError(try validateCoordinateAppPostReceiver(focusedWindowMatches: false))
    }

    func testUnavailableAXLookupAllowsWindowDirectedFallbackButPermissionsDoNot() throws {
        for code in [
            AXError.noValue,
            .notImplemented,
            .attributeUnsupported,
            .cannotComplete,
            .invalidUIElement,
            .failure
        ] {
            XCTAssertFalse(try coordinateHitTestHasElement(code))
        }
        XCTAssertTrue(try coordinateHitTestHasElement(.success))
        for code in [AXError.apiDisabled, .illegalArgument] {
            XCTAssertThrowsError(try coordinateHitTestHasElement(code))
        }
    }

    func testUnknownAXWindowUsesMouseWithoutInvokingAX() throws {
        var mouseCount = 0
        try dispatchCoordinateClick(
            at: point, target: CoordinateClickTarget(
                role: kAXButtonRole,
                frame: bounds,
                actions: [kAXPressAction],
                belongsToWindow: nil
            ),
            button: .left, clickCount: 1, validateWindow: {},
            performAX: { _ in XCTFail("unverified AX target must not execute"); return .success },
            performMouse: { mouseCount += 1 }
        )
        XCTAssertEqual(mouseCount, 1)
    }

    func testMouseRouteSelectedBeforeAnyInput() {
        XCTAssertEqual(coordinateMouseMethod(button: .left, clickCount: 1, globalEnabled: false), .skyClick)
        XCTAssertEqual(coordinateMouseMethod(button: .left, clickCount: 2, globalEnabled: false), .skyClick)
        XCTAssertEqual(coordinateMouseMethod(button: .right, clickCount: 1, globalEnabled: false), .skyClick)
        XCTAssertEqual(coordinateMouseMethod(button: .right, clickCount: 2, globalEnabled: false), .appPost)
        XCTAssertEqual(coordinateMouseMethod(button: .middle, clickCount: 1, globalEnabled: false), .appPost)
        XCTAssertEqual(coordinateMouseMethod(button: .left, clickCount: 3, globalEnabled: false), .appPost)
        XCTAssertEqual(coordinateMouseMethod(button: .left, clickCount: 1, globalEnabled: true), .global)
    }

    func testMouseFailureNeverRetriesAnotherRoute() {
        var calls = 0
        XCTAssertThrowsError(try dispatchCoordinateClick(
            at: point, target: nil, button: .left, clickCount: 1, validateWindow: {},
            performAX: { _ in XCTFail("no AX target"); return .success },
            performMouse: { calls += 1; throw ComputerUseError.message("input may have occurred") }
        ))
        XCTAssertEqual(calls, 1)
    }
}
