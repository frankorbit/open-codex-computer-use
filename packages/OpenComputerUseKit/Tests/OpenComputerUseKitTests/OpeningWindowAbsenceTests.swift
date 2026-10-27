import CoreGraphics
@testable import OpenComputerUseKit
import XCTest

final class OpeningWindowAbsenceTests: XCTestCase {
    private func record(_ id: Int = 10, owner: pid_t = 42, visible: Bool? = nil) -> [String: Any] {
        var value: [String: Any] = [kCGWindowOwnerPID as String: owner, kCGWindowNumber as String: id]
        if let visible { value[kCGWindowIsOnscreen as String] = visible }
        return value
    }

    func testDetachedAuxiliaryRecordsDoNotProveAnExistingWindow() throws {
        var queried: [CGWindowID] = []
        let probe = OpeningWindowAbsence(now: { 0 }, spaces: { queried.append($0); return [] })
        XCTAssertTrue(try probe.isConfirmed(appPID: 42, axWindowCount: 0,
                                            windowInfo: [record(), record(11, visible: false), record(12, owner: 99)],
                                            deadline: 1))
        XCTAssertEqual(queried, [10, 11])
    }

    func testVisibleOtherSpaceAndUnknownWindowsPreventReopen() throws {
        for assigned: [UInt64]? in [nil, [1], [2, 3]] {
            let probe = OpeningWindowAbsence(now: { 0 }, spaces: { _ in assigned })
            XCTAssertFalse(try probe.isConfirmed(appPID: 42, axWindowCount: 0, windowInfo: [record()], deadline: 1))
        }
        let visibleProbe = OpeningWindowAbsence(now: { 0 }, spaces: { _ in
            XCTFail("visible window must stop"); return []
        })
        XCTAssertFalse(try visibleProbe.isConfirmed(appPID: 42, axWindowCount: 0,
                                                    windowInfo: [record(visible: true)], deadline: 1))
    }

    func testUnreadableAndExistingAXWindowsNeverUseCGAsAbsence() throws {
        let probe = OpeningWindowAbsence(now: { 0 }, spaces: { _ in XCTFail("must not probe"); return [] })
        for count: Int? in [nil, 1] {
            XCTAssertFalse(try probe.isConfirmed(appPID: 42, axWindowCount: count, windowInfo: [], deadline: 1))
        }
        XCTAssertFalse(try probe.isConfirmed(appPID: 42, axWindowCount: 0, windowInfo: nil, deadline: 1))
        XCTAssertTrue(try probe.isConfirmed(appPID: 42, axWindowCount: 0, windowInfo: [], deadline: 1))
    }

    func testMalformedMetadataNeverAuthorizesReopen() throws {
        let probe = OpeningWindowAbsence(now: { 0 }, spaces: { _ in XCTFail("invalid metadata"); return [] })
        var malformed = [record()]
        malformed[0][kCGWindowIsOnscreen as String] = "unknown"
        let cases: [[String: Any]] = [[:], [kCGWindowOwnerPID as String: 42],
                                      [kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: -1],
                                      [kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 0],
                                      [kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 1.5], malformed[0]]
        for info in cases {
            XCTAssertFalse(try probe.isConfirmed(appPID: 42, axWindowCount: 0, windowInfo: [info], deadline: 1))
        }
    }

    func testLateOrCancelledSpaceLookupCannotAuthorizeReopen() throws {
        var time = 0.0
        let late = OpeningWindowAbsence(now: { time }, spaces: { _ in time = 1; return [] })
        XCTAssertFalse(try late.isConfirmed(appPID: 42, axWindowCount: 0, windowInfo: [record()], deadline: 1))
        var cancelled = false
        let cancel = OpeningWindowAbsence(now: { 0 }, spaces: { _ in cancelled = true; return [] }, checkCancellation: {
            if cancelled { throw CancellationError() }
        })
        do {
            _ = try cancel.isConfirmed(appPID: 42, axWindowCount: 0, windowInfo: [record()], deadline: 1)
            XCTFail("cancelled observation must stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testServiceBindsAfterDetachedWindowReopenWithoutChangingOtherObservation() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        var time = 0.0
        var dependencies = harness.dependencies
        dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        dependencies.openingWindowReady = { _, _ in harness.opens == 2 }
        dependencies.openingWindowAbsent = { app, deadline in
            try OpeningWindowAbsence(now: { time }, spaces: { _ in [] }).isConfirmed(
                appPID: app.pid, axWindowCount: 0, windowInfo: [self.record(owner: app.pid)], deadline: deadline
            )
        }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 2)
        XCTAssertEqual(harness.builds, 1)
        harness.resolveFailure = nil
        _ = try service.getAppState(app: "Editor")
        XCTAssertEqual(harness.opens, 2)
    }

    func testServiceOnlyReopensOnceForConfirmedDetachedRecords() throws {
        for assigned: [UInt64]? in [[], [7], nil] {
            let harness = OpeningHarness()
            harness.resolveFailure = .appNotFound("Editor")
            var time = 0.0
            var dependencies = harness.dependencies
            dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
            dependencies.openingWindowReady = { _, _ in false }
            dependencies.openingWindowAbsent = { app, deadline in
                try OpeningWindowAbsence(now: { time }, spaces: { _ in assigned }).isConfirmed(
                    appPID: app.pid, axWindowCount: 0, windowInfo: [self.record(owner: app.pid)], deadline: deadline
                )
            }
            let service = ComputerUseService(snapshotDependencies: dependencies)
            XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
            XCTAssertEqual(harness.opens, assigned == [] ? 2 : 1)
            XCTAssertEqual(harness.builds, 0)
            XCTAssertThrowsError(try service.getAppState(app: "test.editor", initialize: true))
            XCTAssertEqual(harness.opens, assigned == [] ? 2 : 1, "pending initialization must not replay")
        }
    }
}
