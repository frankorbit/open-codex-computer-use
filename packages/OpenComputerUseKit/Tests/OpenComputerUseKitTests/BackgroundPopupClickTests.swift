import AppKit
@testable import OpenComputerUseKit
import XCTest

final class BackgroundPopupClickTests: XCTestCase {
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

    private func lease() throws -> HoverPopupLease {
        var cache = HoverPopupCache()
        cache.record([popup()], snapshot: snapshot(), now: 10)
        return try cache.take(token)
    }

    func testBackgroundLeaseUsesPopupPixelsAndCannotChangeMethodOrPolicy() throws {
        let lease = try lease()
        XCTAssertEqual(lease.method, .skyClick)
        XCTAssertEqual(
            try lease.globalPoint(for: CGPoint(x: 100, y: 100), snapshot: snapshot(), now: 11, method: .skyClick),
            CGPoint(x: -250, y: 250)
        )
        for method in [ClickMethod.global, .auto, .appPost, .accessibility] {
            XCTAssertThrowsError(try lease.globalPoint(for: .zero, snapshot: snapshot(), now: 11, method: method))
        }
        unsetenv(modeKey)
        XCTAssertThrowsError(try lease.globalPoint(for: .zero, snapshot: snapshot(), now: 11, method: .skyClick))
        setenv(modeKey, "invalid", 1)
        XCTAssertThrowsError(try lease.globalPoint(for: .zero, snapshot: snapshot(), now: 11, method: .skyClick))
    }

    func testLeaseRejectsExpirationClockRollbackNonfiniteAndRootChanges() throws {
        let lease = try lease()
        XCTAssertNoThrow(try lease.globalPoint(for: .zero, snapshot: snapshot(), now: 40, method: .skyClick))
        for time in [9, 40.001, .nan, .infinity] {
            XCTAssertThrowsError(try lease.globalPoint(for: .zero, snapshot: snapshot(), now: time, method: .skyClick))
        }
        for changed in [snapshot(pid: 12), snapshot(id: 3), snapshot(bounds: rootBounds.offsetBy(dx: 1, dy: 0))] {
            XCTAssertThrowsError(try lease.globalPoint(for: .zero, snapshot: changed, now: 11, method: .skyClick))
        }
        for point in [
            CGPoint(x: -1, y: 0),
            CGPoint(x: 400, y: 0),
            CGPoint(x: 0, y: 200),
            CGPoint(x: CGFloat.infinity, y: 0)
        ] {
            XCTAssertThrowsError(try lease.globalPoint(for: point, snapshot: snapshot(), now: 11, method: .skyClick))
        }
    }

    func testOnlyExplicitBackgroundCapabilityCanEnterCacheAndDuplicateTokensFailClosed() throws {
        var cache = HoverPopupCache()
        var legacy = popup()
        legacy.permitsBackgroundInput = false
        legacy.permitsInput = true
        cache.record([legacy], snapshot: snapshot(), now: 10)
        XCTAssertThrowsError(try cache.take(token))
        cache.record([popup(), popup()], snapshot: snapshot(), now: 10)
        XCTAssertThrowsError(try cache.take(token))
        cache.record([popup()], snapshot: snapshot(pid: 12), now: 10)
        XCTAssertThrowsError(try cache.take(token))
        cache.record([popup()], snapshot: snapshot(id: 2), now: 10)
        XCTAssertThrowsError(try cache.take(token))
        cache.record([popup()], snapshot: snapshot(), now: .nan)
        XCTAssertThrowsError(try cache.take(token))
        cache.record([popup()], snapshot: snapshot(), now: 10)
        XCTAssertThrowsError(try cache.take("unknown"))
        XCTAssertThrowsError(try cache.take(token))
        cache.record([popup()], snapshot: snapshot(), now: 10)
        _ = try cache.take(token.uppercased())
        XCTAssertThrowsError(try cache.take(token))
    }

    func testExactReceiverRequiredEvenForSamePIDOrRootAndNoReceiverLookupOnInvalidMetadata() throws {
        let windows = [window(2, bounds: popupBounds), window(1, bounds: rootBounds)]
        let point = CGPoint(x: -250, y: 250)
        XCTAssertNoThrow(try validateHoverPopupWindows(
            popup(), point: point, snapshot: snapshot(), query: { windows }, mouseReceiver: {
                XCTAssertEqual($0, point); return 2
            }
        ))
        // 包括遮挡、同进程其他窗口、root、无法命中；均不能投递。
        for receiver: CGWindowID? in [nil, 0, 1, 3, 99] {
            XCTAssertThrowsError(try validateHoverPopupWindows(
                popup(),
                point: point,
                snapshot: snapshot(),
                query: { windows }, mouseReceiver: { _ in receiver }
            ))
        }
        var hidden = windows[0]
        hidden[kCGWindowIsOnscreen as String] = false
        var transparent = windows[0]
        transparent[kCGWindowAlpha as String] = 0
        let badLists = [
            [windows[1]], [windows[0]], [windows[0], windows[0], windows[1]],
            [window(2, pid: 12, bounds: popupBounds), windows[1]],
            [windows[0], window(1, pid: 12, bounds: rootBounds)],
            [window(2, bounds: popupBounds.offsetBy(dx: 1, dy: 0)), windows[1]],
            [window(2, bounds: CGRect(x: -300, y: 200, width: 201, height: 100)), windows[1]],
            [windows[0], window(1, bounds: rootBounds.offsetBy(dx: 1, dy: 0))],
            [hidden, windows[1]], [transparent, windows[1]], [windows[1], windows[0]]
        ]
        for changed in badLists {
            XCTAssertThrowsError(try validateHoverPopupWindows(
                popup(),
                point: point,
                snapshot: snapshot(),
                query: { changed }, mouseReceiver: { _ in
                    XCTFail("Invalid metadata must stop before receiver lookup"); return 2
                }
            ))
        }
        XCTAssertThrowsError(try validateHoverPopupWindows(
            popup(),
            point: .zero,
            snapshot: snapshot(),
            query: { windows }, mouseReceiver: { _ in
                XCTFail("Outside popup"); return 2
            }
        ))
    }

    func testValidationFailurePostsNothingAndUnknownSubmissionOrReadbackNeverReplays() throws {
        for stage in 0 ... 2 {
            var cache = HoverPopupCache()
            cache.record([popup()], snapshot: snapshot(), now: 10)
            let lease = try cache.take(token)
            var posts = 0
            var readbacks = 0
            XCTAssertThrowsError(try dispatchPopupClick(method: lease.method, validate: {
                if stage == 0 { throw ComputerUseError.message("receiver changed") }
            }, submit: {
                posts += 1
                if stage == 1 { throw ComputerUseError.message("submission outcome unknown") }
            }, readBack: {
                readbacks += 1
                throw ComputerUseError.message("readback failed")
            })) {
                XCTAssertEqual($0.localizedDescription.contains("input may have occurred"), stage != 0)
            }
            XCTAssertEqual(posts, stage == 0 ? 0 : 1)
            XCTAssertEqual(readbacks, stage == 2 ? 1 : 0)
            XCTAssertThrowsError(try cache.take(token))
        }
    }

    func testGlobalAndAutomaticDispatchAreRejectedBeforeClosuresInBackground() {
        for method in [ClickMethod.global, .auto, .accessibility, .appPost] {
            XCTAssertThrowsError(try dispatchPopupClick(method: method,
                                                        validate: { XCTFail("unexpected validation") },
                                                        submit: { XCTFail("unexpected input") },
                                                        readBack: { XCTFail("unexpected readback") }))
        }
    }

    func testRequestTokenMismatchFailsBeforeLiveValidation() throws {
        let request = try HoverPopupClickRequest(arguments: [
            "popup_token": UUID().uuidString, "x": 1, "y": 1, "click_method": "sky_click"
        ])
        XCTAssertThrowsError(try validateHoverPopupClick(
            lease(),
            request: request,
            snapshot: snapshot(),
            now: { 11 }
        )) {
            XCTAssertTrue($0.localizedDescription.contains("consumed token"))
        }
    }
}

extension BackgroundPopupClickTests {
    func testTTLIsRecheckedAfterSlowReceiverValidationBeforeSubmission() throws {
        let request = try HoverPopupClickRequest(arguments: [
            "popup_token": token, "x": 100, "y": 100, "click_method": "sky_click"
        ])
        let lease = try lease()
        for end in [40.001, Double.nan, 9] {
            var reads = 0
            var validations = 0
            var posts = 0
            XCTAssertThrowsError(try dispatchPopupClick(method: request.method, validate: {
                _ = try validateHoverPopupClick(lease, request: request, snapshot: snapshot(), now: {
                    reads += 1
                    return reads == 1 ? 11 : end
                }, validateReceiver: { popup, point, state, method in
                    validations += 1
                    XCTAssertEqual(popup.windowID, 2)
                    XCTAssertEqual(point, CGPoint(x: -250, y: 250))
                    XCTAssertEqual(state.targetWindowID, 1)
                    XCTAssertEqual(method, .skyClick)
                })
            }, submit: { posts += 1 }, readBack: {}))
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(validations, 1)
            XCTAssertEqual(posts, 0)
        }
    }

    func testValidBackgroundDispatchSubmitsOnceAndConsumesSiblingTokens() throws {
        var cache = HoverPopupCache()
        let second = HoverPopupObservation(
            token: UUID().uuidString, windowID: 3, pid: 11, bounds: popupBounds, captureBounds: popupBounds,
            imageData: Data([1]), pixelSize: CGSize(width: 400, height: 200),
            permitsInput: false, permitsBackgroundInput: true
        )
        cache.record([popup(), second], snapshot: snapshot(), now: 10)
        let lease = try cache.take(token)
        let request = try HoverPopupClickRequest(arguments: [
            "popup_token": token, "x": 100, "y": 100, "click_method": "sky_click"
        ])
        var posts = 0
        let result = try dispatchPopupClick(method: request.method, validate: {
            _ = try validateHoverPopupClick(lease, request: request, snapshot: snapshot(), now: { 11 },
                                            validateReceiver: { popup, point, state, _ in
                                                try validateHoverPopupWindows(popup, point: point, snapshot: state,
                                                                              query: { [
                                                                                  window(2, bounds: popupBounds),
                                                                                  window(1, bounds: rootBounds)
                                                                              ] },
                                                                              mouseReceiver: { _ in 2 })
                                            })
        }, submit: { posts += 1 }, readBack: { "observed" })
        XCTAssertEqual(result, "observed")
        XCTAssertEqual(posts, 1)
        XCTAssertThrowsError(try cache.take(token))
        XCTAssertThrowsError(try cache.take(second.token))
    }
}

extension BackgroundPopupClickTests {
    func testSkyPreparationAndPrimerWaitCrossingTTLStopsTargetDownWithoutReplay() throws {
        for stage in 0 ... 2 {
            var cache = HoverPopupCache()
            cache.record([popup()], snapshot: snapshot(), now: 10)
            let lease = try cache.take(token)
            let request = try HoverPopupClickRequest(arguments: [
                "popup_token": token, "x": 100, "y": 100, "click_method": "sky_click"
            ])
            var clock: TimeInterval = 11
            let validate = {
                _ = try validateHoverPopupClick(lease, request: request, snapshot: self.snapshot(), now: { clock },
                                                validateReceiver: { _, _, _, _ in })
            }
            var posted: [SkyClickEventStep] = []
            XCTAssertThrowsError(try dispatchPopupClick(method: .skyClick, validate: validate, submit: {
                // stage 0 模拟锁/焦点等待；stage 1 在 primer down 后过期；stage 2 在 primer up 后过期。
                if stage == 0 { clock = 41 }
                try dispatchSkyClickEvents(skyClickEventRecipe(clickCount: 1), validateBeforeSubmission: validate,
                                           post: { posted.append($0) }, wait: { _ in
                                               if stage == 1, posted.last?.kind == .down { clock = 41 }
                                               if stage == 2, posted.last?.kind == .up { clock = 41 }
                                           })
            }, readBack: { XCTFail("Rejected submission must not read back as success") })) {
                XCTAssertTrue($0.localizedDescription.contains("input may have occurred"))
            }
            XCTAssertEqual(posted.map(\.kind), stage == 0 ? [] : [.moved, .down, .up])
            XCTAssertFalse(posted.contains { $0.kind == .down && $0.pointKind == .target })
            XCTAssertThrowsError(try cache.take(token))
        }
    }

    func testPrimerClosingMovingOrCoveringPopupPreventsRealDownButKeepsPrimerUp() throws {
        let original = [window(2, bounds: popupBounds), window(1, bounds: rootBounds)]
        let changedStates = [
            [original[1]],
            [window(2, bounds: popupBounds.offsetBy(dx: 1, dy: 0)), original[1]],
            [window(2, pid: 12, bounds: popupBounds), original[1]],
            [original[0], window(1, bounds: rootBounds.offsetBy(dx: 1, dy: 0))],
            original
        ]
        for (index, changed) in changedStates.enumerated() {
            let lease = try lease()
            let request = try HoverPopupClickRequest(arguments: [
                "popup_token": token, "x": 100, "y": 100, "click_method": "sky_click"
            ])
            var windows = original
            var receiver: CGWindowID? = 2
            var posted: [SkyClickEventStep] = []
            let validate = {
                _ = try validateHoverPopupClick(lease, request: request, snapshot: self.snapshot(), now: { 11 },
                                                validateReceiver: { popup, point, state, _ in
                                                    try validateHoverPopupWindows(
                                                        popup,
                                                        point: point,
                                                        snapshot: state,
                                                        query: { windows },
                                                        mouseReceiver: { _ in receiver }
                                                    )
                                                })
            }
            XCTAssertThrowsError(try dispatchPopupClick(method: .skyClick, validate: validate, submit: {
                try dispatchSkyClickEvents(skyClickEventRecipe(clickCount: 1), validateBeforeSubmission: validate,
                                           post: { step in
                                               posted.append(step)
                                               if step.kind == .down, step.pointKind == .primer {
                                                   windows = changed
                                                   if index == changedStates.count - 1 { receiver = 99 }
                                               }
                                           }, wait: { _ in })
            }, readBack: { XCTFail("Unknown effect must not read back as success") })) {
                XCTAssertTrue($0.localizedDescription.contains("input may have occurred"))
            }
            XCTAssertEqual(posted.map(\.kind), [.moved, .down, .up])
            XCTAssertEqual(posted.last?.pointKind, .primer)
        }
    }

    func testLegacyPopupSkySubmissionWithoutRevalidationFailsBeforeInput() {
        XCTAssertThrowsError(try submitHoverPopupClick(popup(), point: .zero, method: .skyClick)) {
            XCTAssertTrue($0.localizedDescription.contains("requires submission validation"))
        }
    }
}
