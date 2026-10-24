import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXActionExecutionTests: XCTestCase {
    private let failures: [AXError] = [
        .cannotComplete, .failure, .actionUnsupported, .attributeUnsupported,
        .noValue, .invalidUIElement, .illegalArgument, .notImplemented, .apiDisabled
    ]

    func testUndeclaredActionIsNotAttempted() throws {
        var events: [String] = []
        let result = try executeAXAction(
            named: "AXPress", availableActions: ["AXConfirm"], repeatCount: 3,
            perform: { events.append("input"); return .success },
            pauseBetweenAttempts: { events.append("pause") }
        )
        XCTAssertEqual(result, .notAttempted)
        XCTAssertTrue(events.isEmpty)
    }

    func testInputTimeoutIsPreparedOnceBeforeTheFirstAttemptOnly() throws {
        var events: [String] = []
        let result = try executeAXAction(
            named: "AXPress", availableActions: ["AXPress"], repeatCount: 2,
            prepare: { events.append("prepare") },
            perform: { events.append("input"); return .success },
            pauseBetweenAttempts: { events.append("pause") }
        )
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events, ["prepare", "input", "pause", "input"])

        var prepared = false
        XCTAssertEqual(try executeAXAction(
            named: "AXPress", availableActions: ["AXConfirm"],
            prepare: { prepared = true }, perform: { .success }
        ), .notAttempted)
        XCTAssertFalse(prepared)
    }

    func testInputGivesTheElementALongerTimeoutThanObservation() {
        var timeouts: [Float] = []
        prepareAXInput(AXUIElementCreateSystemWide()) { _, timeout in
            timeouts.append(timeout)
            return .success
        }
        XCTAssertEqual(timeouts, [2])
        // Observation reads use at most 0.1 s; input must wait for modal sheets and saves.
        XCTAssertGreaterThan(axInputMessagingTimeout, 1)
    }

    func testSuccessfulRepeatedActionKeepsCaseInsensitiveSupportAndPausesOnlyBetweenAttempts() throws {
        var events: [String] = []
        let result = try executeAXAction(
            named: "AXPress", availableActions: ["axpress"], repeatCount: 3,
            perform: { events.append("input"); return .success },
            pauseBetweenAttempts: { events.append("pause") }
        )
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events, ["input", "pause", "input", "pause", "input"])
    }

    func testNonpositiveRepeatCountPreservesSingleAttempt() throws {
        for count in [0, -1] {
            var attempts = 0
            let result = try executeAXAction(
                named: "AXPress", availableActions: ["AXPress"], repeatCount: count,
                perform: { attempts += 1; return .success },
                pauseBetweenAttempts: { XCTFail("Single attempt must not pause") }
            )
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(attempts, 1)
        }
    }

    func testEveryFailureAfterSubmissionStopsRepetitionAndReportsUnknownEffect() {
        for failure in failures {
            var attempts = 0
            XCTAssertThrowsError(try executeAXAction(
                named: "AXPress", availableActions: ["AXPress"], repeatCount: 3,
                perform: { attempts += 1; return failure },
                pauseBetweenAttempts: { XCTFail("Failed input must not pause or repeat") }
            )) { error in
                guard case let ComputerUseError.message(message) = error else {
                    return XCTFail("Expected a tool error, got \(error)")
                }
                XCTAssertTrue(message.contains("effect is unknown"))
                XCTAssertTrue(message.contains("attempt 1/3"))
                XCTAssertTrue(message.contains("returned \(failure.rawValue)"))
            }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testAXOpenAttributeUnsupportedIsAnErrorNotSuccess() {
        var attempts = 0
        XCTAssertThrowsError(try executeAXAction(
            named: "AXOpen", availableActions: ["AXOpen"],
            perform: { attempts += 1; return .attributeUnsupported },
            pauseBetweenAttempts: { XCTFail("Failed AXOpen must not pause") }
        ))
        XCTAssertEqual(attempts, 1)
    }

    func testUnknownEffectStopsLaterActionsCandidatesAndHID() {
        for failure in failures {
            var events: [String] = []
            XCTAssertThrowsError(try runCandidates(
                [["AXPress", "AXConfirm", "AXOpen"], ["AXPress"]],
                perform: { candidate, action in
                    events.append("\(candidate):\(action)")
                    return failure
                },
                fallback: { events.append("HID") }
            ))
            XCTAssertEqual(events, ["0:AXPress"])
        }
    }

    func testPartialRepeatSuccessStopsRemainingRepeatsCandidatesAndHID() {
        for failure in failures {
            for repeatCount in [2, 3] {
                var events: [String] = []
                XCTAssertThrowsError(try runCandidates(
                    [["AXPress", "AXConfirm"], ["AXOpen"]], repeatCount: repeatCount,
                    perform: { candidate, action in
                        events.append("\(candidate):\(action)")
                        return events.count == 1 ? .success : failure
                    },
                    fallback: { events.append("HID") }
                )) { error in
                    XCTAssertTrue(error.localizedDescription
                        .contains("attempt 2/\(repeatCount) after 1 successful AX returns"))
                }
                XCTAssertEqual(events, ["0:AXPress", "0:AXPress"])
            }
        }
    }

    func testUnattemptedActionsCanAdvanceToSupportedCandidateOrHID() throws {
        var events: [String] = []
        try runCandidates([[], ["AXConfirm"]], perform: { candidate, action in
            events.append("\(candidate):\(action)")
            return .success
        }, fallback: { events.append("HID") })
        XCTAssertEqual(events, ["1:AXConfirm"])

        events.removeAll()
        try runCandidates([[], []], perform: { _, _ in
            XCTFail("Undeclared actions must not execute")
            return .success
        }, fallback: { events.append("HID") })
        XCTAssertEqual(events, ["HID"])
    }

    /// 注入候选和输入回执，验证执行器抛错能中断调用方的选路，不触碰真实 AX 或 HID。
    private func runCandidates(
        _ candidates: [[String]],
        repeatCount: Int = 1,
        perform: (Int, String) -> AXError,
        fallback: () -> Void
    ) throws {
        for (index, actions) in candidates.enumerated() {
            for action in ["AXPress", "AXConfirm", "AXOpen"] {
                switch try executeAXAction(
                    named: action, availableActions: actions, repeatCount: repeatCount,
                    perform: { perform(index, action) }, pauseBetweenAttempts: {}
                ) {
                case .completed:
                    return
                case .notAttempted:
                    continue
                }
            }
        }
        fallback()
    }
}
