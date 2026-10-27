import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXSidebarPreflightTests: XCTestCase {
    private final class Harness {
        var budget: TimeInterval = 0.35
        var checks = 0
        var failCheckAt: Int?
        var checkError: Error = axInputPreflightFailure("original deadline exceeded")
        var setupResult: AXError = .success
        var restoreResult: AXError = .success
        var queryResult: (AXError, Bool) = (.success, true)
        var queryError: Error?
        var queries = 0
        var timeouts: [Float] = []
        var events: [String] = []

        func run() throws -> (AXError, Bool) {
            try readAXSidebarPreflight(
                remaining: { self.budget },
                checkDeadline: {
                    self.events.append("check")
                    self.checks += 1
                    if self.checks == self.failCheckAt { throw self.checkError }
                },
                setTimeout: { timeout in
                    self.events.append(timeout == 0 ? "restore" : "setup")
                    self.timeouts.append(timeout)
                    return timeout == 0 ? self.restoreResult : self.setupResult
                },
                query: {
                    self.events.append("query")
                    self.queries += 1
                    if let error = self.queryError { throw error }
                    return self.queryResult
                }
            )
        }
    }

    private let failures: [AXError] = [
        .failure, .illegalArgument, .invalidUIElement, .invalidUIElementObserver, .cannotComplete,
        .attributeUnsupported, .actionUnsupported, .notificationUnsupported, .notImplemented,
        .notificationAlreadyRegistered, .notificationNotRegistered, .apiDisabled, .noValue,
        .parameterizedAttributeUnsupported, .notEnoughPrecision
    ]

    func testTimeoutBoundsQueryAndRestoresDefaultInOrder() throws {
        for budget in [0.35, 0.02, 0.0005] {
            let harness = Harness()
            harness.budget = budget
            let result = try harness.run()
            XCTAssertEqual(result.0, .success)
            XCTAssertTrue(result.1)
            XCTAssertEqual(harness.timeouts, [Float(min(0.05, budget)), 0])
            XCTAssertEqual(harness.events, ["check", "setup", "check", "query", "check", "restore", "check"])
            XCTAssertEqual(harness.queries, 1)
        }
    }

    func testExpiredOrInvalidRemainingBudgetNeverSetsTimeoutOrQueries() {
        for budget in [0, -0.01, Double.nan, Double.infinity] {
            let harness = Harness()
            harness.budget = budget
            XCTAssertThrowsError(try harness.run())
            XCTAssertTrue(harness.timeouts.isEmpty)
            XCTAssertEqual(harness.queries, 0)
        }
    }

    func testCancellationAndDeadlineAtEachCheckpointStopAndRestore() {
        for checkpoint in 1 ... 4 {
            for cancellation in [true, false] {
                let harness = Harness()
                harness.failCheckAt = checkpoint
                harness.checkError = cancellation ? CancellationError() : axInputPreflightFailure("original deadline")
                var followups = 0
                XCTAssertThrowsError(try {
                    _ = try harness.run()
                    followups += 1
                }()) { error in
                    if cancellation {
                        XCTAssertTrue(error is CancellationError)
                    } else {
                        XCTAssertEqual(error.localizedDescription, harness.checkError.localizedDescription)
                    }
                }
                XCTAssertEqual(harness.queries, checkpoint >= 3 ? 1 : 0)
                XCTAssertEqual(harness.timeouts, checkpoint == 1 ? [] : [0.05, 0])
                XCTAssertEqual(followups, 0)
            }
        }
    }

    func testQueryAXErrorsRemainUnchangedForCaller() throws {
        for error in failures where error != .apiDisabled {
            let harness = Harness()
            harness.queryResult = (error, false)
            let result = try harness.run()
            XCTAssertEqual(result.0, error)
            XCTAssertFalse(result.1)
            XCTAssertEqual(harness.queries, 1)
            XCTAssertEqual(harness.timeouts, [0.05, 0])
        }
    }

    func testSetupAXErrorsStopBeforeQueryAndStillRestore() {
        for error in failures where error != .apiDisabled {
            let harness = Harness()
            harness.setupResult = error
            XCTAssertThrowsError(try harness.run()) { thrown in
                XCTAssertTrue(thrown.localizedDescription.contains("timeout setup failed (AX \(error.rawValue))"))
            }
            XCTAssertEqual(harness.queries, 0)
            XCTAssertEqual(harness.timeouts, [0.05, 0])
        }
    }

    func testRestoreAXErrorsNeverReturnSuccessfulQueryAsUsable() {
        for error in failures where error != .apiDisabled {
            let harness = Harness()
            harness.restoreResult = error
            XCTAssertThrowsError(try harness.run()) { thrown in
                XCTAssertTrue(thrown.localizedDescription.contains("timeout restore failed (AX \(error.rawValue))"))
            }
            XCTAssertEqual(harness.queries, 1)
            XCTAssertEqual(harness.timeouts, [0.05, 0])
        }
    }

    func testQueryThrownErrorIsPreservedAfterRestoringTimeout() {
        let harness = Harness()
        harness.queryError = CancellationError()
        XCTAssertThrowsError(try harness.run()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(harness.timeouts, [0.05, 0])
        XCTAssertEqual(harness.queries, 1)
    }

    func testGenericOwnerResultPreservesRawErrorAndPid() throws {
        for error: AXError in [.success, .invalidUIElement, .cannotComplete] {
            var timeouts: [Float] = []
            let result = try readAXSidebarPreflight(
                remaining: { 0.01 }, checkDeadline: {},
                setTimeout: { timeouts.append($0); return .success },
                query: { (error, pid_t(42)) }
            )
            XCTAssertEqual(result.0, error)
            XCTAssertEqual(result.1, 42)
            XCTAssertEqual(timeouts, [0.01, 0])
        }
    }
}

extension AXSidebarPreflightTests {
    func testPermissionDenialFromSetupOrQueryWinsOverLaterDeadlineOrCancellation() {
        for duringSetup in [true, false] {
            for cancellation in [true, false] {
                let harness = Harness()
                if duringSetup {
                    harness.setupResult = .apiDisabled
                    harness.failCheckAt = 2
                } else {
                    harness.queryResult = (.apiDisabled, false)
                    harness.failCheckAt = 3
                }
                harness.checkError = cancellation ? CancellationError() : axInputPreflightFailure("expired")
                XCTAssertThrowsError(try harness.run()) { self.verifyPermissionDenied($0) }
                XCTAssertEqual(harness.checks, duringSetup ? 1 : 2)
                XCTAssertEqual(harness.queries, duringSetup ? 0 : 1)
                XCTAssertEqual(harness.timeouts, [0.05, 0])
            }
        }
    }

    func testRestorePermissionDenialWinsOverOtherFailure() {
        for checkpoint: Int? in [nil, 2, 3] {
            let harness = Harness()
            harness.failCheckAt = checkpoint
            harness.checkError = CancellationError()
            harness.restoreResult = .apiDisabled
            XCTAssertThrowsError(try harness.run()) { self.verifyPermissionDenied($0) }
            XCTAssertEqual(harness.timeouts, [0.05, 0])
            XCTAssertEqual(harness.queries, checkpoint == 2 ? 0 : 1)
        }
    }

    func testQueryPermissionDenialSurvivesNonPermissionRestoreFailure() {
        let harness = Harness()
        harness.queryResult = (.apiDisabled, false)
        harness.restoreResult = .invalidUIElement
        XCTAssertThrowsError(try harness.run()) { self.verifyPermissionDenied($0) }
        XCTAssertEqual(harness.timeouts, [0.05, 0])
        XCTAssertEqual(harness.queries, 1)
    }

    private func verifyPermissionDenied(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let ComputerUseError.permissionDenied(message) = error else {
            return XCTFail("真实权限错误不得被超时、取消或清理错误覆盖", file: file, line: line)
        }
        XCTAssertTrue(message.hasPrefix("Accessibility permission is required"), file: file, line: line)
    }
}
