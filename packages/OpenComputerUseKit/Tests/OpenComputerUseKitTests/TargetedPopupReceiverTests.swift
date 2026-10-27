import AppKit
@testable import OpenComputerUseKit
import XCTest

final class TargetedPopupReceiverTests: XCTestCase {
    private let modeKey = "OPEN_COMPUTER_USE_EXECUTION_MODE"
    private var oldMode: String?
    private let token = "00000000-0000-0000-0000-000000000001"
    private let rootBounds = CGRect(x: -500, y: 100, width: 800, height: 600)
    private let popupBounds = CGRect(x: -300, y: 200, width: 200, height: 100)

    override func setUp() {
        super.setUp()
        oldMode = ProcessInfo.processInfo.environment[modeKey]
        setenv(modeKey, "background", 1)
    }

    override func tearDown() {
        if let oldMode { setenv(modeKey, oldMode, 1) } else { unsetenv(modeKey) }
        super.tearDown()
    }

    private func snapshot(pid: pid_t = 11, id: CGWindowID = 1, bounds: CGRect? = nil) -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(
                name: "fixture",
                bundleIdentifier: "test.popup",
                pid: pid,
                runningApplication: .current
            ),
            windowTitle: "fixture", windowBounds: bounds ?? rootBounds, targetWindowID: id, targetWindowLayer: 0,
            screenshotData: nil, mode: .accessibility, treeLines: [], focusedSummary: nil, focusedElement: nil,
            selectedText: nil, windowElement: nil, elements: [:]
        )
    }

    private func popup() -> HoverPopupObservation {
        HoverPopupObservation(
            token: token, windowID: 2, pid: 11, bounds: popupBounds, captureBounds: popupBounds,
            imageData: Data([1]), pixelSize: CGSize(width: 400, height: 200),
            permitsInput: false, permitsBackgroundInput: true
        )
    }

    private func window(_ id: CGWindowID, pid: pid_t = 11, bounds: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: bounds.dictionaryRepresentation, kCGWindowAlpha as String: 1,
         kCGWindowIsOnscreen as String: true, kCGWindowLayer as String: 0]
    }

    func testTargetedPopupIgnoresOtherAppsButKeepsExactWindowAndSameAppObstructionChecks() throws {
        let point = CGPoint(x: -250, y: 250)
        let original = [window(2, bounds: popupBounds), window(1, bounds: rootBounds)]
        let otherApp = window(99, pid: 22, bounds: popupBounds)
        func validate(_ windows: [[String: Any]], spaces: @escaping (CGWindowID) -> [UInt64]? = { _ in [1] }) throws {
            try validateHoverPopupWindows(
                popup(), point: point, snapshot: snapshot(), method: .skyClick, query: { windows },
                mouseReceiver: { _ in XCTFail("Targeted input must not query the desktop receiver"); return nil },
                spacesForWindow: spaces
            )
        }
        XCTAssertNoThrow(try validate([otherApp] + original))
        XCTAssertThrowsError(try validate([window(3, bounds: popupBounds)] + original))
        XCTAssertThrowsError(try validate([window(3, bounds: popupBounds)] + original, spaces: { _ in nil }))
        XCTAssertNoThrow(try validate([window(3, bounds: popupBounds)] + original, spaces: { $0 == 3 ? [2] : [1] }))
        XCTAssertThrowsError(try validate([[kCGWindowBounds as String: popupBounds.dictionaryRepresentation]] +
                original))
        XCTAssertThrowsError(try validate([otherApp, window(2, pid: 22, bounds: popupBounds), original[1]]))
        XCTAssertThrowsError(try validate([otherApp, original[1]]))
        XCTAssertThrowsError(try validate([original[1], original[0]]))
        XCTAssertThrowsError(try validate([window(2, bounds: popupBounds.offsetBy(dx: 1, dy: 0)), original[1]]))
        XCTAssertThrowsError(try validate([original[0], window(1, bounds: rootBounds.offsetBy(dx: 1, dy: 0))]))
        for method in [ClickMethod.auto, .accessibility, .appPost] {
            XCTAssertThrowsError(try validateHoverPopupWindows(
                popup(), point: point, snapshot: snapshot(), method: method,
                query: { XCTFail("Unsupported route must fail before reading windows"); return original },
                mouseReceiver: { _ in nil }
            ))
        }
    }

    func testTargetedPopupRevalidatesAfterSpaceLookupBeforeReturning() throws {
        let original = [window(3, bounds: popupBounds), window(2, bounds: popupBounds), window(1, bounds: rootBounds)]
        var windows = original
        XCTAssertThrowsError(try validateHoverPopupWindows(
            popup(), point: CGPoint(x: -250, y: 250), snapshot: snapshot(), method: .skyClick,
            query: { windows }, mouseReceiver: { _ in XCTFail("No desktop lookup"); return nil },
            spacesForWindow: { id in
                // 第一次 Space 查询期间弹层移动，第二次身份读取必须拒绝旧凭证。
                windows[1] = self.window(2, bounds: self.popupBounds.offsetBy(dx: 1, dy: 0))
                return id == 3 ? [2] : [1]
            }
        ))
    }

    private func validate(
        _ lease: HoverPopupLease, request: HoverPopupClickRequest, windows: () -> [[String: Any]]
    ) throws {
        _ = try validateHoverPopupClick(lease, request: request, snapshot: snapshot(), now: { 11 },
                                        validateReceiver: { popup, point, state, method in
                                            try validateHoverPopupWindows(
                                                popup, point: point, snapshot: state, method: method,
                                                query: windows,
                                                mouseReceiver: { _ in XCTFail("No desktop lookup"); return nil },
                                                spacesForWindow: { _ in [1] }
                                            )
                                        })
    }

    func testTargetedPopupProductionDispatchPostsOnceOrStopsAfterMoveWithoutReplay() throws {
        for stage in 0 ... 2 {
            var cache = HoverPopupCache()
            cache.record([popup()], snapshot: snapshot(), now: 10)
            let lease = try cache.take(token)
            let request = try HoverPopupClickRequest(arguments: [
                "popup_token": token, "x": 100, "y": 100, "click_method": "sky_click"
            ])
            var windows = [
                window(99, pid: 22, bounds: popupBounds),
                window(2, bounds: popupBounds),
                window(1, bounds: rootBounds)
            ]
            if stage == 0 { windows.insert(window(3, bounds: popupBounds), at: 0) }
            var posted: [SkyClickEventStep] = []
            var readbacks = 0
            let validate = { try self.validate(lease, request: request, windows: { windows }) }
            let run = {
                try dispatchPopupClick(method: request.method, validate: validate, submit: {
                    try dispatchSkyClickEvents(
                        skyClickEventRecipe(clickCount: 1, profile: .popup),
                        validateBeforeSubmission: validate,
                        post: { step in
                            posted.append(step)
                            if stage == 1, step.kind == .moved {
                                windows.insert(self.window(3, bounds: self.popupBounds), at: 0)
                            }
                        },
                        wait: { _ in }
                    )
                }, readBack: { readbacks += 1 })
            }
            if stage < 2 {
                XCTAssertThrowsError(try run())
                XCTAssertEqual(posted.map(\.kind), stage == 0 ? [] : [.moved])
                XCTAssertEqual(readbacks, 0)
            } else {
                XCTAssertNoThrow(try run())
                XCTAssertEqual(posted.filter { $0.kind == .down && $0.pointKind == .target }.count, 1)
                XCTAssertEqual(readbacks, 1)
            }
            XCTAssertThrowsError(try cache.take(token))
        }
    }
}
