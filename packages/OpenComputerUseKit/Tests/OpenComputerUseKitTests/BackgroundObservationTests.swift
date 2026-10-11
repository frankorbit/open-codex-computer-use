import Foundation
@testable import OpenComputerUseKit
import XCTest

final class BackgroundObservationTests: XCTestCase {
    func testExistingWindowNeedsNoDelay() throws {
        let value = try observeWithoutActivation(wait: { _ in XCTFail("unexpected wait") }, build: { 42 })
        XCTAssertEqual(value, 42)
    }

    func testNewWindowCanBecomeReadyWithoutActivationFallback() throws {
        var attempts = 0
        var delays: [TimeInterval] = []
        let value = try observeWithoutActivation(wait: { delays.append($0) }, build: {
            attempts += 1
            if attempts < 3 { throw ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage) }
            return 42
        })
        XCTAssertEqual(value, 42)
        XCTAssertEqual(delays, [0.1, 0.1])
    }

    func testMissingWindowHasBoundedReadOnlyRetries() {
        var attempts = 0
        var waits = 0
        XCTAssertThrowsError(try observeWithoutActivation(wait: { _ in waits += 1 }, build: { () -> Int in
            attempts += 1
            throw ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage)
        }))
        XCTAssertEqual(attempts, 6)
        XCTAssertEqual(waits, 5)
    }

    func testPermissionAndOtherFailuresDoNotRetry() {
        for error in [ComputerUseError.permissionDenied("denied"), .stateUnavailable("stale"), .message("transport")] {
            var attempts = 0
            XCTAssertThrowsError(try observeWithoutActivation(
                wait: { _ in XCTFail("unexpected wait") },
                build: { () -> Int in
                    attempts += 1
                    throw error
                }
            ))
            XCTAssertEqual(attempts, 1)
        }
    }
}
