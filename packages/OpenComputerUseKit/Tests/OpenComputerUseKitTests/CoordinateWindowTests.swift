import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class CoordinateWindowTests: XCTestCase {
    private let bounds = CGRect(x: -900, y: 120, width: 800, height: 600)
    private let point = CGPoint(x: -600, y: 400)

    private func window(id: Int = 42, pid: Int = 1234, rect: CGRect? = nil, visible: Bool = true, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: (rect ?? bounds).dictionaryRepresentation,
         kCGWindowIsOnscreen as String: NSNumber(value: visible), kCGWindowAlpha as String: NSNumber(value: alpha)]
    }

    private func validate(_ windows: [[String: Any]], global: Bool = false, at location: CGPoint? = nil, spaces: @escaping (CGWindowID) -> [UInt64]? = { _ in [1] }) throws {
        try validateCoordinateWindow(windowID: 42, pid: 1234, bounds: bounds, point: location ?? point,
                                     windows: windows, requireUnoccludedPoint: global, spacesForWindow: spaces)
    }

    func testValidWindowDoesNotNeedAX() throws {
        try validate([window()])
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
        for location in [CGPoint(x: -901, y: 400), CGPoint(x: CGFloat.nan, y: 400), CGPoint(x: -600, y: CGFloat.infinity)] {
            XCTAssertThrowsError(try validate([window()], at: location))
        }
    }

    func testSameProcessPopupCoveringPointRejects() {
        XCTAssertThrowsError(try validate([window(id: 43), window()]))
    }

    func testOtherAppCoverAllowsWindowDirectedButNotGlobalInput() throws {
        let windows = [window(id: 43, pid: 4321), window()]
        try validate(windows)
        XCTAssertThrowsError(try validate(windows, global: true))
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

    func testPIDOnlyMouseRequiresActualForegroundReceiver() throws {
        try validateCoordinateAppPostReceiver(frontmostPID: 1234, expectedPID: 1234, focusedWindowMatches: true)
        XCTAssertThrowsError(try validateCoordinateAppPostReceiver(frontmostPID: nil, expectedPID: 1234, focusedWindowMatches: true))
        XCTAssertThrowsError(try validateCoordinateAppPostReceiver(frontmostPID: 5678, expectedPID: 1234, focusedWindowMatches: true))
        XCTAssertThrowsError(try validateCoordinateAppPostReceiver(frontmostPID: 1234, expectedPID: 1234, focusedWindowMatches: false))
    }

    func testAXAbsenceAndCommunicationFailuresRemainDistinct() throws {
        XCTAssertFalse(try coordinateHitTestHasElement(.noValue))
        XCTAssertFalse(try coordinateHitTestHasElement(.notImplemented))
        XCTAssertTrue(try coordinateHitTestHasElement(.success))
        for code in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .illegalArgument, .failure] {
            XCTAssertThrowsError(try coordinateHitTestHasElement(code))
        }
    }

    func testUnknownAXWindowUsesMouseWithoutInvokingAX() throws {
        var mouseCount = 0
        try dispatchCoordinateClick(
            at: point, target: CoordinateClickTarget(role: kAXButtonRole, frame: bounds, actions: [kAXPressAction], belongsToWindow: nil),
            button: .left, clickCount: 1, validateWindow: {},
            performAX: { _ in XCTFail("unverified AX target must not execute"); return .success },
            performMouse: { mouseCount += 1 }
        )
        XCTAssertEqual(mouseCount, 1)
    }

    func testCoordinateAutoReadbackNeverActivatesOrReopensWindow() {
        XCTAssertEqual(clickActionSnapshotRecoveryPolicy(for: .auto, coordinateInput: true), .readOnly)
        XCTAssertEqual(clickActionSnapshotRecoveryPolicy(for: .auto, coordinateInput: false), .allowActivation)
    }

    func testMouseRouteSelectedBeforeAnyInput() {
        XCTAssertEqual(coordinateMouseMethod(button: .left, clickCount: 1, globalEnabled: false), .skyClick)
        XCTAssertEqual(coordinateMouseMethod(button: .left, clickCount: 2, globalEnabled: false), .skyClick)
        XCTAssertEqual(coordinateMouseMethod(button: .right, clickCount: 1, globalEnabled: false), .appPost)
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
