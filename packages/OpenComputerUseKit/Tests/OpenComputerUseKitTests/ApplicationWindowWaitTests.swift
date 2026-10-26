import Foundation
@testable import OpenComputerUseKit
import XCTest

final class ApplicationWindowWaitTests: XCTestCase {
    func testReadyWindowReturnsWithoutSleeping() throws {
        var sleeps = 0
        let waiter = ApplicationWindowWait(now: { 10 }, sleep: { _ in sleeps += 1 })
        try waiter.run(validate: {}, probe: { deadline in
            XCTAssertEqual(deadline, 13)
            return true
        })
        XCTAssertEqual(sleeps, 0)
    }

    func testDelayedWindowGetsThreeSecondBudgetAndStopsWhenReady() throws {
        var time = 10.0
        var probes = 0
        let waiter = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        try waiter.run(validate: {}, probe: { _ in
            probes += 1
            return time >= 11.2
        })
        XCTAssertGreaterThan(probes, 6)
        XCTAssertLessThan(time, 11.4)
    }

    func testMissingWindowTimesOutAndDoesNotProbeAfterDeadline() {
        var time = 10.0
        var probes = 0
        let waiter = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        XCTAssertThrowsError(try waiter.run(validate: {}, probe: { deadline in
            XCTAssertLessThan(time, deadline)
            probes += 1
            return false
        })) { error in
            XCTAssertEqual(error.localizedDescription, applicationWindowTimeoutMessage)
        }
        XCTAssertEqual(time, 13, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(probes, 31)
    }

    func testSlowProbeConsumesDeadlineAndCannotPublishLateSuccess() {
        var time = 0.0
        var sleeps = 0
        let waiter = ApplicationWindowWait(now: { time }, sleep: { _ in sleeps += 1 })
        XCTAssertThrowsError(try waiter.run(validate: {}, probe: { _ in
            time = 3.1
            return true
        }))
        XCTAssertEqual(sleeps, 0)
    }

    func testPermissionFailureDoesNotRetry() {
        var probes = 0
        let waiter = ApplicationWindowWait(now: { 0 }, sleep: { _ in XCTFail("must not wait") })
        XCTAssertThrowsError(try waiter.run(validate: {}, probe: { _ in
            probes += 1
            throw ComputerUseError.permissionDenied("denied")
        })) { error in XCTAssertEqual(error.localizedDescription, "denied") }
        XCTAssertEqual(probes, 1)
    }

    func testCancellationDuringProbePreventsSuccess() {
        var cancelled = false
        let waiter = ApplicationWindowWait(now: { 0 }, sleep: { _ in XCTFail("must not wait") }, checkCancellation: {
            if cancelled { throw CancellationError() }
        })
        XCTAssertThrowsError(try waiter.run(validate: {}, probe: { _ in
            cancelled = true
            return true
        })) { error in XCTAssertTrue(error is CancellationError) }
    }

    func testProcessChangeDuringProbePreventsSuccess() {
        var changed = false
        let waiter = ApplicationWindowWait(now: { 0 }, sleep: { _ in XCTFail("must not wait") })
        XCTAssertThrowsError(try waiter.run(validate: {
            if changed { throw ComputerUseError.stateUnavailable("process changed") }
        }, probe: { _ in
            changed = true
            return true
        })) { error in XCTAssertEqual(error.localizedDescription, "process changed") }
    }

    func testColdStartProbesWithoutRenderingUntilReady() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        var time = 0.0
        var probes = 0
        var dependencies = harness.dependencies
        dependencies.openingWindowAbsent = { _, _ in false }
        dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        dependencies.openingWindowReady = { app, _ in
            XCTAssertEqual(app.pid, harness.openedApp.pid)
            XCTAssertEqual(harness.builds, 0)
            probes += 1
            return time >= 1.2
        }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertGreaterThan(probes, 6)
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builds, 1)
    }

    func testStartupTimeoutKeepsPendingAndAllowsReadOnlyRecovery() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        var time = 0.0
        var dependencies = harness.dependencies
        dependencies.openingWindowAbsent = { _, _ in false }
        dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        dependencies.openingWindowReady = { _, _ in false }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true)) { error in
            XCTAssertEqual(error.localizedDescription, applicationWindowTimeoutMessage)
        }
        XCTAssertEqual(harness.builds, 0)
        // 就绪超时不证明没有窗口；挂起期间再次初始化不再打开。
        XCTAssertEqual(harness.opens, 1)
        XCTAssertThrowsError(try service.getAppState(app: "test.editor", initialize: true))
        XCTAssertEqual(harness.opens, 1)
        harness.resolveFailure = nil
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builds, 1)
    }

    func testWindowlessStartupIsReopenedOnceInTheBackgroundThenSucceeds() throws {
        // Numbers 在无窗口状态下被强制结束后，后台冷启动不弹打开面板，后台 reopen 后才出现。
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        var time = 0.0
        var probesBeforeReopen = 0
        var dependencies = harness.dependencies
        dependencies.openingWindowAbsent = { _, _ in true }
        dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        dependencies.openingWindowReady = { app, _ in
            XCTAssertEqual(app.pid, harness.openedApp.pid)
            if harness.opens < 2 { probesBeforeReopen += 1; return false }
            return true
        }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertGreaterThan(probesBeforeReopen, 20, "reopen only after the first full wait")
        XCTAssertEqual(harness.opens, 2)
        XCTAssertEqual(harness.builds, 1)
    }

    func testReadyStartupNeverReopens() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        var time = 0.0
        var dependencies = harness.dependencies
        dependencies.openingWindowAbsent = { _, _ in false }
        dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        dependencies.openingWindowReady = { _, _ in time >= 2.5 }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 1)
    }

    func testReopenThatReturnsAnotherProcessStopsWithoutBuilding() {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        var time = 0.0
        var opens = 0
        var dependencies = harness.dependencies
        dependencies.openingWindowAbsent = { _, _ in true }
        dependencies.prepareOpen = { _ in
            ApplicationOpeningRequest(identity: .bundle("test.editor"), perform: {
                opens += 1
                return opens == 1 ? harness.openedApp : harness.app
            })
        }
        dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
        dependencies.openingWindowReady = { _, _ in false }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("different application process"))
        }
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(harness.builds, 0)
    }

    func testExistingWindowNeverUsesStartupProbe() throws {
        let harness = OpeningHarness()
        var dependencies = harness.dependencies
        dependencies.openingWindowAbsent = { _, _ in false }
        dependencies.openingWindowReady = { _, _ in XCTFail("existing window must not poll"); return false }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        _ = try service.getAppState(app: "Editor")
        XCTAssertEqual(harness.opens, 0)
    }

    func testExitedOpenedProcessFailsBeforeProbe() {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        var dependencies = harness.dependencies
        dependencies.openingWindowAbsent = { _, _ in false }
        dependencies.processIdentity = { _ in nil }
        dependencies.openingWindowReady = { _, _ in XCTFail("exited process must not poll"); return true }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builds, 0)
    }

    func testLateAbsenceAndUnreadableProbeNeverReopen() {
        for late in [false, true] {
            let harness = OpeningHarness()
            harness.resolveFailure = .appNotFound("Editor")
            var time = 0.0
            var dependencies = harness.dependencies
            dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
            dependencies.openingWindowReady = { _, _ in time = 3.1; return true }
            dependencies.openingWindowAbsent = { _, deadline in
                if late { time = deadline; return true }
                return false
            }
            let service = ComputerUseService(snapshotDependencies: dependencies)
            XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
            XCTAssertEqual(harness.opens, 1)
            XCTAssertEqual(harness.builds, 0)
        }
    }

    func testAbsenceProbePermissionAndCancellationPreventReopen() {
        for permission in [false, true] {
            let harness = OpeningHarness()
            harness.resolveFailure = .appNotFound("Editor")
            var time = 0.0
            var dependencies = harness.dependencies
            dependencies.openingWindowWait = ApplicationWindowWait(now: { time }, sleep: { time += $0 })
            dependencies.openingWindowReady = { _, _ in false }
            dependencies.openingWindowAbsent = { _, _ in
                if permission { throw ComputerUseError.permissionDenied("denied") }
                throw CancellationError()
            }
            let service = ComputerUseService(snapshotDependencies: dependencies)
            XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true)) { error in
                if permission {
                    XCTAssertEqual(error.localizedDescription, "denied")
                } else {
                    XCTAssertTrue(error is CancellationError)
                }
            }
            XCTAssertEqual(harness.opens, 1)
        }
    }
}
