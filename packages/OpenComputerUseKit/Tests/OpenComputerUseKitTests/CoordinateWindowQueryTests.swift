import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class CoordinateWindowQueryTests: XCTestCase {
    private let bounds = CGRect(x: -900, y: 120, width: 800, height: 600)
    private let point = CGPoint(x: -600, y: 400)

    private func window(_ id: Int = 42, pid: Int = 1234, visible: Bool = true,
                        rect: CGRect? = nil, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: (rect ?? bounds).dictionaryRepresentation,
         kCGWindowIsOnscreen as String: visible, kCGWindowAlpha as String: alpha]
    }

    private func validate(
        all: [[String: Any]], at location: CGPoint? = nil,
        spaces: (CGWindowID) -> [UInt64]? = { _ in [1] },
        query: (CGWindowListOption, CGWindowID) -> [[String: Any]]?
    ) throws {
        let location = location ?? point
        try validateCoordinateWindow(
            windowID: 42, pid: 1234, bounds: bounds, point: location,
            windows: all, requireUnoccludedPoint: false, spacesForWindow: spaces,
            backgroundWindows: { isOnScreen in
                try coordinateWindowObstructions(
                    windowID: 42, pid: 1234, bounds: self.bounds, point: location,
                    isOnScreen: isOnScreen, query: query
                )
            }
        )
    }

    func testUnorderedAllCannotCreateFalseBlockOrHideRealBlock() throws {
        var calls = 0
        try validate(all: [window(43), window()], spaces: { _ in
            XCTFail("No candidate needs a Space query"); return nil
        }, query: { options, relative in
            calls += 1
            XCTAssertEqual(options, [.optionOnScreenAboveWindow, .optionIncludingWindow])
            XCTAssertEqual(relative, 42)
            return [self.window()]
        })
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try validate(all: [window(), window(43)]) { _, _ in
            [self.window(43), self.window()]
        })
    }

    func testIdentityAndForegroundDoNotQueryBackgroundEvidenceOrSpaces() throws {
        for identityOnly in [true, false] {
            try validateCoordinateWindow(
                windowID: 42, pid: 1234, bounds: bounds, point: point,
                windows: [window(43), window()], requireUnoccludedPoint: !identityOnly,
                identityOnly: identityOnly, spacesForWindow: { _ in XCTFail("Unexpected Space query"); return nil },
                mouseReceiver: { _ in 42 }, backgroundWindows: { _ in
                    XCTFail("Foreground must not acquire background evidence")
                    throw ComputerUseError.stateUnavailable("Unexpected query")
                }
            )
        }
    }

    func testNilMissingReusedMovedOrChangedVisibilityAfterQueryRejects() {
        let responses: [[[String: Any]]?] = [
            nil, [], [window(43)], [window(pid: 999)],
            [window(rect: bounds.offsetBy(dx: 1, dy: 0))], [window(visible: false)], [window(alpha: 0)]
        ]
        for response in responses {
            XCTAssertThrowsError(try validate(all: [window()]) { _, _ in response })
        }
    }

    func testIrrelevantCandidatesDoNotRequireSpaces() throws {
        for candidate in [window(43, pid: 555), window(43, visible: false), window(43, alpha: 0),
                          window(43, rect: bounds.offsetBy(dx: 1000, dy: 0))] {
            try validate(all: [window()], spaces: { _ in XCTFail("Irrelevant candidate"); return nil }, query: { _, _ in
                [candidate, self.window()]
            })
        }
    }

    func testOnlyRelevantUnknownOrSharedSpaceRejects() throws {
        try validate(all: [window()], spaces: { $0 == 42 ? [1] : [2] }, query: { _, _ in
            [self.window(43), self.window()]
        })
        for spaces: (CGWindowID) -> [UInt64]? in [{ _ in nil }, { _ in [] }, { _ in [1] }] {
            XCTAssertThrowsError(try validate(all: [window()], spaces: spaces) { _, _ in
                [self.window(43), self.window()]
            })
        }
    }

    func testOffscreenNoCandidateDoesNotRequireSpacesOrAboveQuery() throws {
        var calls: [CGWindowListOption] = []
        try validate(all: [window(visible: false)], spaces: { _ in
            XCTFail("No candidate"); return nil
        }, query: { options, relative in
            calls.append(options)
            if options == .optionOnScreenOnly {
                XCTAssertEqual(relative, kCGNullWindowID)
                return [self.window(43, pid: 555)]
            }
            XCTAssertEqual(options, .optionIncludingWindow)
            XCTAssertEqual(relative, 42)
            return [self.window(visible: false)]
        })
        XCTAssertEqual(calls, [.optionOnScreenOnly, .optionIncludingWindow])
    }

    func testOffscreenDifferentSpaceSupportedButUnknownOrderCannotPretendNoCover() throws {
        let query: (CGWindowListOption, CGWindowID) -> [[String: Any]]? = { options, _ in
            options == .optionOnScreenOnly ? [self.window(43)] : [self.window(visible: false)]
        }
        try validate(all: [window(43), window(visible: false)], spaces: { $0 == 42 ? [1] : [2] }, query: query)
        XCTAssertThrowsError(try validate(all: [window(visible: false)], query: query)) { error in
            XCTAssertTrue(error.localizedDescription.contains("relative order"))
        }
        XCTAssertThrowsError(try validate(all: [window(visible: false)], spaces: { _ in nil }, query: query))
    }

    func testOffscreenQueryFailureAndVisibilityRacesReject() {
        for phase in [0, 1, 2, 3] {
            XCTAssertThrowsError(try validate(all: [window(visible: false)]) { options, _ in
                if options == .optionOnScreenOnly {
                    if phase == 0 { return nil }
                    return phase == 2 ? [self.window()] : []
                }
                if phase == 1 { return nil }
                return [self.window(visible: phase == 3)]
            })
        }
    }

    func testAppPostScrollAndDragReacquireEvidenceAfterAXAndForEveryPoint() throws {
        // 单点模拟 scroll/middle click；双点模拟 drag，共用生产 app_post 的前后校验边界。
        for points in [[point], [point, CGPoint(x: -590, y: 400)]] {
            for movedDuringAX in [false, true] {
                var afterAX = false
                var queries = 0
                var submissions = 0
                let perform = {
                    try dispatchAppPostInput(policy: .background, validateReceiver: {
                        try validateCoordinateAppPostTarget(validateWindow: {
                            for point in points {
                                try self.validate(all: [self.window()], at: point) { _, _ in
                                    queries += 1
                                    if afterAX, movedDuringAX {
                                        return [self.window(rect: self.bounds.offsetBy(dx: 1, dy: 0))]
                                    }
                                    return [self.window()]
                                }
                            }
                        }, readFocusedWindowMatch: { afterAX = true; return nil })
                    }, submit: { submissions += 1 })
                }
                if movedDuringAX {
                    XCTAssertThrowsError(try perform())
                    XCTAssertEqual(queries, points.count + 1)
                    XCTAssertEqual(submissions, 0)
                } else {
                    try perform()
                    XCTAssertEqual(queries, points.count * 2)
                    XCTAssertEqual(submissions, 1)
                }
            }
        }
    }
}
