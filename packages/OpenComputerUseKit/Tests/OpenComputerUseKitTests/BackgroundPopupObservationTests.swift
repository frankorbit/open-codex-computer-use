import AppKit
import CoreGraphics
@testable import OpenComputerUseKit
import XCTest

final class BackgroundPopupObservationTests: XCTestCase {
    private typealias Observation = HoverPopupObservation
    private let root = Observation.Window(windowID: 10, pid: 123, bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
    private let popup = Observation.Window(
        windowID: 11,
        pid: 123,
        bounds: CGRect(x: 100, y: 100, width: 100, height: 100)
    )
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

    private func image() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        return try XCTUnwrap(encodeScreenshot(
            for: XCTUnwrap(context.makeImage()),
            config: ImageCaptureConfig(maxDimension: 10)
        ).data)
    }

    private func capture(
        readState: @escaping () -> Observation.State?, allowInput: Bool = false, allowBackgroundInput: Bool = false,
        captureImage: @escaping (Observation.Window) throws -> Data?
    ) -> [Observation] {
        Observation.capture(
            rootWindowID: root.windowID, pid: root.pid, rootBounds: root.bounds,
            requireForeground: false, allowInput: allowInput,
            allowBackgroundInput: allowBackgroundInput,
            dependencies: .init(readState: readState, captureImage: { window in
                try captureImage(window).map { .init(data: $0, captureBounds: window.bounds) }
            })
        )
    }

    func testBackgroundCandidatePassesRealFilterAndNativeContentHasNoClickCredential() throws {
        let data = try image()
        var captures = 0
        let state = Observation.State(windows: [popup, root], rootIsForeground: false)
        let candidate = try XCTUnwrap(capture(readState: { state }, captureImage: { _ in
            captures += 1; return data
        }).first)
        XCTAssertEqual(captures, 1)
        XCTAssertFalse(candidate.permitsInput)
        let text = candidate.content.compactMap { $0.dictionary["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Observation only"))
        XCTAssertTrue(text.contains("local to this observed window"))
        XCTAssertFalse(text.contains("global"))
        XCTAssertFalse(text.contains("popup_token"))
        XCTAssertFalse(text.contains("app.click"))
        let metadata = (candidate.content.last?.dictionary["_meta"] as? [String: Any])?["ocuPopup"] as? [String: Any]
        XCTAssertNil(metadata?["token"])
        XCTAssertEqual(metadata?["observationOnly"] as? Bool, true)
    }

    func testExplicitBackgroundCapabilityIssuesOnlySkyClickTokenWithoutForegroundRequirement() throws {
        let data = try image()
        let state = Observation.State(windows: [popup, root], rootIsForeground: false)
        let candidate = try XCTUnwrap(capture(
            readState: { state }, allowBackgroundInput: true, captureImage: { _ in data }
        ).first)
        XCTAssertFalse(candidate.permitsInput)
        XCTAssertTrue(candidate.permitsBackgroundInput)
        let text = candidate.content.compactMap { $0.dictionary["text"] as? String }.joined(separator: "\n")
        for fragment in ["click_method:\"sky_click\"", "clickMethod:\"sky_click\"", "Candidate only, not parent proof",
                         "30 seconds", "no activation, global input or fallback", "Never replay"] {
            XCTAssertTrue(text.contains(fragment), fragment)
        }
        let metadata = (candidate.content.last?.dictionary["_meta"] as? [String: Any])?["ocuPopup"] as? [String: Any]
        XCTAssertEqual(metadata?["token"] as? String, candidate.token)
        XCTAssertEqual(metadata?["clickMethod"] as? String, "sky_click")
        XCTAssertEqual(metadata?["backgroundClickCapable"] as? Bool, true)
        XCTAssertEqual(metadata?["observationOnly"] as? Bool, false)
        XCTAssertFalse(candidate.content(policy: .compatible)
            .contains { ($0.dictionary["text"] as? String)?.contains("popup_token") == true })
        setenv("OPEN_COMPUTER_USE_EXECUTION_MODE", "invalid", 1)
        XCTAssertFalse(candidate.content
            .contains { ($0.dictionary["text"] as? String)?.contains("popup_token") == true })
    }

    func testBackgroundCapabilityDoesNotBypassRootOrPopupStabilityChecks() throws {
        let data = try image()
        let initial = Observation.State(windows: [popup, root], rootIsForeground: false)
        let moved = Observation.Window(
            windowID: popup.windowID,
            pid: popup.pid,
            bounds: popup.bounds.offsetBy(dx: 1, dy: 0)
        )
        for failure in 1 ... 4 {
            var reads = 0
            XCTAssertTrue(capture(readState: {
                reads += 1
                return reads == failure ? nil : initial
            }, allowBackgroundInput: true, captureImage: { _ in data }).isEmpty)
        }
        var state = initial
        XCTAssertTrue(capture(readState: { state }, allowBackgroundInput: true, captureImage: { _ in
            state = .init(windows: [moved, self.root], rootIsForeground: false)
            return data
        }).isEmpty)
    }

    func testRootIdentityGeometryAndVisibilityFailuresAtEveryReadDiscardBatch() throws {
        let data = try image()
        let initial = Observation.State(windows: [popup, root], rootIsForeground: false)
        let moved = Observation.Window(
            windowID: root.windowID,
            pid: root.pid,
            bounds: root.bounds.offsetBy(dx: 1, dy: 0)
        )
        let reused = Observation.Window(windowID: root.windowID, pid: 456, bounds: root.bounds)
        var hidden = root
        hidden.isOnscreen = false
        for invalid: Observation.State? in [nil, .init(windows: [popup]), .init(windows: [popup, moved]),
                                            .init(windows: [popup, reused]), .init(windows: [popup, hidden])] {
            for failure in 1 ... 4 {
                var reads = 0
                XCTAssertTrue(capture(readState: {
                    reads += 1
                    return reads == failure ? invalid : initial
                }, captureImage: { _ in data }).isEmpty)
            }
        }
    }

    func testOtherProcessesIndependentWindowsAndChangingCandidateAreExcluded() throws {
        let data = try image()
        let other = Observation.Window(windowID: popup.windowID, pid: 456, bounds: popup.bounds)
        for state in [Observation.State(windows: [other, root], rootIsForeground: false),
                      Observation.State(
                          windows: [popup, root],
                          independentWindowIDs: [popup.windowID],
                          rootIsForeground: false
                      )] {
            XCTAssertTrue(capture(
                readState: { state },
                captureImage: { _ in XCTFail("excluded candidate"); return data }
            ).isEmpty)
        }
        var reads = 0
        let changed = Observation.Window(
            windowID: popup.windowID,
            pid: popup.pid,
            bounds: popup.bounds.offsetBy(dx: 1, dy: 0)
        )
        XCTAssertTrue(capture(readState: {
            reads += 1
            return .init(windows: [reads >= 3 ? changed : self.popup, self.root], rootIsForeground: false)
        }, captureImage: { _ in data }).isEmpty)
    }

    func testForegroundChangeKeepsObservationButRevokesCompatibilityLease() throws {
        let data = try image()
        for backgroundRead in 1 ... 4 {
            var reads = 0
            let candidate = try XCTUnwrap(capture(readState: {
                reads += 1
                return .init(windows: [self.popup, self.root], rootIsForeground: reads != backgroundRead)
            }, allowInput: true, captureImage: { _ in data }).first)
            XCTAssertFalse(candidate.permitsInput)
            XCTAssertFalse(candidate.content(policy: .compatible)
                .contains { ($0.dictionary["text"] as? String)?.contains("global") == true })
        }
        let compatible = try XCTUnwrap(capture(readState: { .init(windows: [self.popup, self.root]) }, allowInput: true,
                                               captureImage: { _ in data }).first)
        XCTAssertTrue(compatible.permitsInput)
        XCTAssertTrue(compatible.content(policy: .compatible)
            .contains { ($0.dictionary["text"] as? String)?.contains("global") == true })
        XCTAssertFalse(compatible.content(policy: .background)
            .contains { ($0.dictionary["text"] as? String)?.contains("global") == true })
    }

    func testStrictCacheCannotIssueLeaseEvenForInjectedForegroundCandidate() throws {
        let data = try image()
        let candidate = try XCTUnwrap(capture(readState: { .init(windows: [self.popup, self.root]) }, allowInput: true,
                                              captureImage: { _ in data }).first)
        let snapshot = AppSnapshot(
            app: RunningAppDescriptor(
                name: "test",
                bundleIdentifier: "test.popup",
                pid: root.pid,
                runningApplication: .current
            ),
            windowTitle: "test", windowBounds: root.bounds, targetWindowID: root.windowID, targetWindowLayer: 0,
            screenshotData: nil, mode: .accessibility, treeLines: [], focusedSummary: nil, focusedElement: nil,
            selectedText: nil, windowElement: nil, elements: [:]
        )
        var cache = HoverPopupCache()
        cache.record([candidate], snapshot: snapshot, now: 1)
        unsetenv("OPEN_COMPUTER_USE_EXECUTION_MODE")
        XCTAssertThrowsError(try cache.take(candidate.token))
        var observationOnly = candidate
        observationOnly.permitsInput = false
        cache.record([observationOnly], snapshot: snapshot, now: 1)
        XCTAssertThrowsError(try cache.take(candidate.token))
        cache.record([candidate], snapshot: snapshot, now: 1)
        XCTAssertNoThrow(try cache.take(candidate.token))
    }

    func testNativeServiceReportsObservationLimitWhenRealCaptureCannotVerifyRoot() throws {
        let snapshot = AppSnapshot(
            app: RunningAppDescriptor(
                name: "test",
                bundleIdentifier: "test.popup",
                pid: root.pid,
                runningApplication: .current
            ),
            windowTitle: "test", windowBounds: root.bounds, targetWindowID: root.windowID, targetWindowLayer: 0,
            screenshotData: nil, mode: .accessibility, treeLines: [], focusedSummary: nil, focusedElement: nil,
            selectedText: nil, windowElement: nil, elements: [:]
        )
        let service = ComputerUseService(
            snapshots: ["test.popup": snapshot],
            snapshotDependencies: SnapshotDependencies(
                resolve: { _ in XCTFail("must not resolve"); return snapshot.app },
                build: { _, _, _, policy in XCTAssertEqual(policy, .readOnly); return snapshot }
            )
        )
        // 使用真实 capture；缺少 AXWindow 时必须明确说明限制，且无需调用 GUI。
        let result = try service.hover(app: "test.popup", arguments: ["observe_only": true])
        let text = result.content.compactMap { $0.dictionary["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Popup observation incomplete"))
        XCTAssertTrue(text.contains("does not prove no popup exists"))
        XCTAssertFalse(text.contains("popup_token"))
    }
}
