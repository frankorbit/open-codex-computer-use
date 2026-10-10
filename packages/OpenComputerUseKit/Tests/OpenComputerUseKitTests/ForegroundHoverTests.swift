import Foundation
@testable import OpenComputerUseKit
import XCTest

final class ForegroundHoverTests: XCTestCase {
    func testHoverIsExplicitlyOptInAndDoesNotChangeDefaultSurface() {
        XCTAssertEqual(ToolDefinitions.available(environment: [:]).map(\.name), ToolDefinitions.all.map(\.name))
        XCTAssertFalse(foregroundHoverEnabled(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1"]))
        XCTAssertTrue(ToolDefinitions.available(environment: ["OPEN_COMPUTER_USE_FOREGROUND_HOVER": "1"])
            .contains { $0.name == "hover" })
    }

    func testRequestAcceptsElementOrCoordinatesAndDefaultsDwell() throws {
        let element = try HoverRequest(arguments: ["element_index": "34"])
        guard case let .element(index) = element.target else {
            XCTFail("Expected element")
            return
        }
        XCTAssertEqual(index, "34")
        XCTAssertEqual(element.durationMilliseconds, 500)
        let coordinates = try HoverRequest(arguments: ["x": 10.5, "y": 20, "duration_ms": 2000])
        guard case let .coordinates(x, y) = coordinates.target else {
            XCTFail("Expected point")
            return
        }
        XCTAssertEqual(x, 10.5)
        XCTAssertEqual(y, 20)
        XCTAssertEqual(coordinates.durationMilliseconds, 2000)
    }

    func testInvalidRequestsAreRejectedBeforeDispatch() {
        let invalid: [[String: Any]] = [
            [:], ["x": 1], ["y": 1], ["x": true, "y": 1], ["x": 1, "y": Double.nan],
            ["x": "1", "y": 1], ["x": Double.infinity, "y": 1],
            ["element_index": "34", "x": 1], ["element_index": "34", "y": 1],
            ["element_index": true], ["element_index": "bad"], ["element_index": -1],
            ["element_index": "34", "duration_ms": -1],
            ["element_index": "34", "duration_ms": 2001],
            ["element_index": "34", "duration_ms": 1.5],
            ["element_index": "34", "duration_ms": true],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try HoverRequest(arguments: arguments), "\(arguments)")
        }
    }

    func testNumericIndexBoundsCannotTrap() throws {
        let boundary = Double(Int.max)
        for value: Any in [boundary, boundary.nextUp, NSNumber(value: UInt64.max), -Double.infinity, 1.5] {
            XCTAssertThrowsError(try HoverRequest(arguments: ["element_index": value]))
        }
        let request = try HoverRequest(arguments: ["element_index": boundary.nextDown])
        guard case let .element(index) = request.target else {
            XCTFail("Expected integer index")
            return
        }
        XCTAssertEqual(index, String(Int(exactly: boundary.nextDown) ?? -1))
    }

    func testHoverAlwaysObservesAfterOneMoveAndDwell() throws {
        var calls: [String] = []
        let result = try dispatchForegroundHover(
            validateTarget: { calls.append("target") },
            prepare: { calls.append("prepare") },
            validateReceiver: { calls.append("receiver") },
            submit: { calls.append("move") },
            dwell: { calls.append("dwell") },
            readBack: { calls.append("observe"); return "fresh state" }
        )
        XCTAssertEqual(calls, ["target", "prepare", "receiver", "move", "dwell", "observe"])
        XCTAssertEqual(result, "fresh state")
    }

    func testStaleTargetOrChangedReceiverNeverMoves() {
        for failedStage in ["target", "prepare", "receiver"] {
            var moves = 0
            var observations = 0
            func stage(_ name: String) throws {
                if failedStage == name {
                    throw ComputerUseError.stateUnavailable("changed")
                }
            }
            XCTAssertThrowsError(try dispatchForegroundHover(
                validateTarget: { try stage("target") },
                prepare: { try stage("prepare") },
                validateReceiver: { try stage("receiver") },
                submit: { moves += 1 },
                dwell: {},
                readBack: { observations += 1 }
            )) { error in
                XCTAssertFalse(error.localizedDescription.contains("input may have occurred"))
            }
            XCTAssertEqual(moves, 0)
            XCTAssertEqual(observations, 0)
        }
    }

    func testSubmissionAndObservationFailureNeverReplay() {
        for failMove in [true, false] {
            var moves = 0
            var observations = 0
            XCTAssertThrowsError(try dispatchForegroundHover(
                validateTarget: {},
                prepare: {},
                validateReceiver: {},
                submit: {
                    moves += 1
                    if failMove {
                        throw ComputerUseError.message("transport error")
                    }
                },
                dwell: {},
                readBack: {
                    observations += 1
                    throw ComputerUseError.message("readback error")
                }
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("input may have occurred"))
                XCTAssertTrue(error.localizedDescription.contains("No retry"))
            }
            XCTAssertEqual(moves, 1)
            XCTAssertEqual(observations, failMove ? 0 : 1)
        }
    }

    func testHoverWithoutObservationCannotResolveAnotherWindow() {
        let key = "OPEN_COMPUTER_USE_FOREGROUND_HOVER"
        let old = ProcessInfo.processInfo.environment[key]
        setenv(key, "1", 1)
        defer { if let old {
            setenv(key, old, 1)
        } else {
            unsetenv(key)
        } }
        var builds = 0
        let service = ComputerUseService(snapshotDependencies: SnapshotDependencies(
            resolve: { _ in
                XCTFail("Input must not resolve a new target"); throw ComputerUseError.message("unexpected")
            },
            build: { _, _, _, _ in builds += 1; throw ComputerUseError.message("unexpected") }
        ))
        XCTAssertThrowsError(try service.hover(app: "test.editor", arguments: ["element_index": "1"]))
        XCTAssertThrowsError(try service.hover(app: "test.editor", arguments: ["x": 10, "y": 20]))
        XCTAssertEqual(builds, 0)
    }

    func testHoverDiagnosticsAreNotMislabeledAsClick() {
        let result = InputDiagnostics.result(tool: "hover") { .text("fresh observation") }
        let metadata = (result["_meta"] as? [String: Any])?["ocuDiagnostic"] as? [String: String]
        XCTAssertEqual(metadata?["tool"], "hover")
        XCTAssertEqual(metadata?["status"], "returned")
    }
}
