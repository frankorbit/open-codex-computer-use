import AppKit
@testable import OpenComputerUseKit
import XCTest

final class PopupReceiverRevalidationTests: XCTestCase {
    private let token = "00000000-0000-0000-0000-000000000001"
    private let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let popupBounds = CGRect(x: 200, y: 200, width: 200, height: 100)
    private var oldMode: String?

    override func setUp() {
        super.setUp()
        oldMode = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_EXECUTION_MODE"]
        setenv("OPEN_COMPUTER_USE_EXECUTION_MODE", "background", 1)
    }

    override func tearDown() {
        if let oldMode {
            setenv("OPEN_COMPUTER_USE_EXECUTION_MODE", oldMode, 1)
        } else {
            unsetenv("OPEN_COMPUTER_USE_EXECUTION_MODE")
        }
        super.tearDown()
    }

    private var popup: HoverPopupObservation {
        HoverPopupObservation(token: token, windowID: 2, pid: 11, bounds: popupBounds,
                              captureBounds: popupBounds, imageData: Data([1]),
                              pixelSize: CGSize(width: 400, height: 200),
                              permitsInput: false, permitsBackgroundInput: true)
    }

    private var snapshot: AppSnapshot {
        AppSnapshot(app: RunningAppDescriptor(name: "fixture", bundleIdentifier: "test.popup", pid: 11,
                                              runningApplication: .current),
                    windowTitle: "fixture", windowBounds: bounds, targetWindowID: 1, targetWindowLayer: 0,
                    screenshotData: nil, mode: .accessibility, treeLines: [], focusedSummary: nil,
                    focusedElement: nil, selectedText: nil, windowElement: nil, elements: [:])
    }

    private func window(_ id: UInt32, pid: Int32 = 11, bounds: CGRect, visible: Bool = true) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: bounds.dictionaryRepresentation, kCGWindowAlpha as String: 1,
         kCGWindowIsOnscreen as String: visible, kCGWindowLayer as String: 0]
    }

    private var windows: [[String: Any]] {
        [window(2, bounds: popupBounds), window(1, bounds: bounds)]
    }

    private var request: HoverPopupClickRequest {
        get throws {
            try HoverPopupClickRequest(arguments: [
                "popup_token": token, "x": 100, "y": 100, "click_method": "sky_click"
            ])
        }
    }

    func testStableReceiverQueriesMetadataBeforeAndAfterExactlyOnce() throws {
        var events: [String] = []
        try validateHoverPopupWindows(popup, point: CGPoint(x: 250, y: 250), snapshot: snapshot, query: {
            events.append("query")
            return self.windows
        }, mouseReceiver: { _ in
            events.append("receiver")
            return 2
        })
        XCTAssertEqual(events, ["query", "receiver", "query"])
    }

    func testReceiverReturningSameIDCannotHideMetadataChangesDuringItsCallback() {
        let original = windows
        var transparent = original[0]
        transparent[kCGWindowAlpha as String] = 0
        let after: [[[String: Any]]?] = [
            [window(2, bounds: popupBounds.offsetBy(dx: 1, dy: 0)), original[1]],
            [window(2, bounds: popupBounds.insetBy(dx: 1, dy: 0)), original[1]],
            [original[0], window(1, bounds: bounds.offsetBy(dx: 1, dy: 0))],
            [window(2, pid: 12, bounds: popupBounds), original[1]],
            [original[0], window(1, pid: 12, bounds: bounds)],
            [window(2, bounds: popupBounds, visible: false), original[1]],
            [original[0], window(1, bounds: bounds, visible: false)],
            [transparent, original[1]], [original[1], original[0]],
            [original[0], original[0], original[1]], [original[1]], [original[0]], nil
        ]
        for changed in after {
            var current: [[String: Any]]? = original
            var reads = 0
            XCTAssertThrowsError(try validateHoverPopupWindows(
                popup, point: CGPoint(x: 250, y: 250), snapshot: snapshot,
                query: { reads += 1; return current }, mouseReceiver: { _ in
                    // 小幅移位后原落点仍在 popup 内，系统仍会返回同一个 ID。
                    current = changed
                    return 2
                }
            ))
            XCTAssertEqual(reads, 2)
        }
    }

    func testTTLStillExpiresDuringFinalMetadataQuery() throws {
        var cache = HoverPopupCache()
        cache.record([popup], snapshot: snapshot, now: 10)
        let lease = try cache.take(token)
        let request = try request
        var clock: TimeInterval = 11
        var reads = 0
        var posts = 0
        XCTAssertThrowsError(try dispatchPopupClick(method: .skyClick, validate: {
            _ = try validateHoverPopupClick(lease, request: request, snapshot: snapshot, now: { clock },
                                            validateReceiver: { popup, point, snapshot, _ in
                                                try validateHoverPopupWindows(
                                                    popup, point: point, snapshot: snapshot, query: {
                                                        reads += 1
                                                        if reads == 2 { clock = 40.001 }
                                                        return self.windows
                                                    }, mouseReceiver: { _ in 2 }
                                                )
                                            })
        }, submit: { posts += 1 }, readBack: { XCTFail("Expired lease must not read back") }))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(posts, 0)
        XCTAssertThrowsError(try cache.take(token))
    }

    func testReceiverWaitAfterPrimerMovesPopupAndStopsTargetDownWithoutReplay() throws {
        var cache = HoverPopupCache()
        cache.record([popup], snapshot: snapshot, now: 10)
        let lease = try cache.take(token)
        let request = try request
        var current = windows
        var posted: [SkyClickEventStep] = []
        let validate = {
            _ = try validateHoverPopupClick(lease, request: request, snapshot: self.snapshot, now: { 11 },
                                            validateReceiver: { popup, point, snapshot, _ in
                                                try validateHoverPopupWindows(
                                                    popup, point: point, snapshot: snapshot,
                                                    query: { current }, mouseReceiver: { _ in
                                                        if posted.last?.kind == .up {
                                                            current[0] = self.window(
                                                                2, bounds: self.popupBounds.offsetBy(dx: 1, dy: 0)
                                                            )
                                                        }
                                                        return 2
                                                    }
                                                )
                                            })
        }
        XCTAssertThrowsError(try dispatchPopupClick(method: .skyClick, validate: validate, submit: {
            try dispatchSkyClickEvents(skyClickEventRecipe(clickCount: 1), validateBeforeSubmission: validate,
                                       post: { posted.append($0) }, wait: { _ in })
        }, readBack: { XCTFail("Uncertain primer effect must not read back as success") })) {
            XCTAssertTrue($0.localizedDescription.contains("input may have occurred"))
        }
        XCTAssertEqual(posted.map(\.kind), [.moved, .down, .up])
        XCTAssertEqual(posted.last?.pointKind, .primer)
        XCTAssertThrowsError(try cache.take(token))
    }
}
