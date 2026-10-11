@testable import OpenComputerUseKit
import XCTest

final class SkyKeyboardFocusTests: XCTestCase {
    private enum Failure: Error { case prepare, input, cleanup }

    func testPreparationFailureCleansUpWithoutSendingInput() {
        var cleanupCount = 0
        XCTAssertThrowsError(try withSkyKeyboardFocus(
            begin: { 1 }, prepare: { _ in throw Failure.prepare },
            deliver: { XCTFail("must not deliver after focus failure") },
            end: { _ in cleanupCount += 1 },
        )) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(cleanupCount, 1)
    }

    func testInputFailureCleansUpExactlyOnceWithoutReplay() {
        var attempts = 0
        var cleanupCount = 0
        XCTAssertThrowsError(try withSkyKeyboardFocus(
            begin: { 1 }, prepare: { _ in },
            deliver: { attempts += 1; throw Failure.input },
            end: { _ in cleanupCount += 1 },
        )) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(cleanupCount, 1)
    }

    func testCleanupFailureIsSurfacedEvenWhenInputAlsoFailed() {
        for inputFails in [false, true] {
            var attempts = 0
            var cleanupCount = 0
            XCTAssertThrowsError(try withSkyKeyboardFocus(
                begin: { 1 }, prepare: { _ in },
                deliver: { attempts += 1; if inputFails { throw Failure.input } },
                end: { _ in cleanupCount += 1; throw Failure.cleanup },
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("release synthetic focus"))
                XCTAssertTrue(error.localizedDescription.contains("unknown"))
            }
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(cleanupCount, 1)
        }
    }

    func testBackgroundTakeoverBeforeDeliveryStopsInputAndReleasesFocus() {
        var currentPID: Int32 = 1
        var cleaned = false
        XCTAssertThrowsError(try withSkyKeyboardFocus(
            begin: { Int32(2) },
            prepare: { targetPID in
                currentPID = targetPID
                try validateSkyKeyboardBackground(
                    required: true, initialPID: 1, currentPID: currentPID,
                    targetPID: targetPID, inputMayHaveOccurred: false,
                )
            },
            deliver: { XCTFail("background takeover must stop delivery") },
            end: { _ in cleaned = true },
        )) { XCTAssertTrue($0.localizedDescription.contains("No keyboard input was sent")) }
        XCTAssertTrue(cleaned)
    }

    func testBackgroundTakeoverAfterDeliveryReportsUnknown() {
        XCTAssertThrowsError(try validateSkyKeyboardBackground(
            required: true, initialPID: 1, currentPID: 2, targetPID: 2,
            inputMayHaveOccurred: true,
        )) { XCTAssertTrue($0.localizedDescription.contains("effect is unknown")) }
    }

    func testExistingForegroundAndUserSwitchToOtherAppRemainAllowed() throws {
        for (required, initial, current) in [(true, 2, 2), (true, 1, 3), (true, 1, 1), (false, 1, 2)] {
            try validateSkyKeyboardBackground(
                required: required, initialPID: Int32(initial), currentPID: Int32(current),
                targetPID: 2, inputMayHaveOccurred: false,
            )
        }
    }

    func testTargetBecomingForegroundBetweenTextChunksStopsRemainingText() {
        var currentPID: Int32 = 1
        var submissions = 0
        XCTAssertThrowsError(try deliverKeyboardTextChunks([[65], [66]], validateReceiver: {
            try validateSkyKeyboardBackground(
                required: true, initialPID: 1, currentPID: currentPID, targetPID: 2,
                inputMayHaveOccurred: false,
            )
        }, submit: { _ in
            submissions += 1
            currentPID = 2
        })) { XCTAssertTrue($0.localizedDescription.contains("some text may already have been entered")) }
        XCTAssertEqual(submissions, 1)
    }

    func testTargetBecomingForegroundDuringMenuLookupPreventsBothRoutes() {
        for found in [true, false] {
            var currentPID: Int32 = 1
            XCTAssertThrowsError(try dispatchSkyMenuKey(
                findMenuItem: { currentPID = 2; return found ? 1 : nil },
                validateReceiver: {
                    try validateSkyKeyboardBackground(
                        required: true, initialPID: 1, currentPID: currentPID, targetPID: 2,
                        inputMayHaveOccurred: false,
                    )
                },
                pressMenuItem: { _ in XCTFail("must not press menu after takeover") },
                postKey: { XCTFail("must not send key after takeover") },
            ))
        }
    }
}
