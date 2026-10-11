import Foundation
@testable import OpenComputerUseKit
import XCTest

private final class DiagnosticCollector: @unchecked Sendable {
    // 测试观察器可能跨线程调用，所有访问都由同一把锁保护。
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }; storage.append(value)
    }

    var records: [String] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

final class InputDiagnosticsTests: XCTestCase {
    func testSingleForegroundFailuresPreserveStageAndSanitizedCauseWithoutReplay() throws {
        let stages: [ForegroundClickStage] = [.targetValidation, .activation, .receiverValidation, .submission]
        for (index, failedStage) in stages.enumerated() {
            let collector = DiagnosticCollector()
            var calls: [ForegroundClickStage] = []
            let step: (ForegroundClickStage) throws -> Void = { stage in
                calls.append(stage)
                if stage == failedStage { throw ComputerUseError.stateUnavailable("private-window-title-and-message") }
            }
            // 通过真实分派器及 MCP 共用的结果封装，验证 Agent 最终收到的错误。
            let result = InputDiagnostics.$observer.withValue({ collector.append($0) }) {
                InputDiagnostics.result(tool: "click_foreground_once") {
                    try dispatchForegroundClick(authorization: .hostSingleClick,
                        validateTarget: { try step(.targetValidation) }, prepare: { try step(.activation) },
                        validateReceiver: { try step(.receiverValidation) }, submit: { try step(.submission) })
                    return .text("unexpected success")
                }
            }
            XCTAssertEqual(calls, Array(stages.prefix(index + 1)))
            XCTAssertEqual(result["isError"] as? Bool, true)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertTrue(text.contains("stage=\(failedStage.rawValue)"))
            XCTAssertTrue(text.contains("cause=state_unavailable"))
            XCTAssertTrue(text.contains("input_may_have_occurred=\(failedStage == .submission)"))
            XCTAssertTrue(text.contains("activation_may_have_occurred=\(failedStage != .targetValidation)"))
            XCTAssertTrue(text.contains("do not replay automatically"))
            XCTAssertEqual(text.contains("No HID mouse input was sent"), failedStage != .submission)
            XCTAssertFalse(text.contains("private-window-title"))
            let records = try collector.records.map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
            }
            let failures = records.filter { $0["event"] == "foreground_click_failed" }
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures.first?["stage"], failedStage.rawValue)
            XCTAssertEqual(failures.first?["cause"], "state_unavailable")
            let metadata = try XCTUnwrap((result["_meta"] as? [String: Any])?["ocuDiagnostic"] as? [String: String])
            XCTAssertEqual(failures.first?["diagnostic_id"], metadata["id"])
            XCTAssertEqual(metadata["status"], "failed")
            XCTAssertFalse(collector.records.joined().contains("private-window-title"))
        }
    }

    func testSingleForegroundCauseWhitelistDoesNotExposeAssociatedValues() {
        let privateText = "private-request-and-file-path"
        let cases: [(Error, ForegroundClickFailure.Cause)] = [
            (ComputerUseError.invalidArguments(privateText), .invalidArguments),
            (ComputerUseError.permissionDenied(privateText), .permissionDenied),
            (ComputerUseError.stateUnavailable(privateText), .stateUnavailable),
            (ComputerUseError.appNotFound(privateText), .appNotFound),
            (ComputerUseError.unsupportedTool(privateText), .unsupportedTool),
            (ComputerUseError.message(privateText), .operationFailed),
            (NSError(domain: privateText, code: 42, userInfo: [NSLocalizedDescriptionKey: privateText]), .unexpectedError)
        ]
        for (error, expected) in cases {
            let failure = ForegroundClickFailure(stage: .submission, cause: .init(error))
            XCTAssertEqual(failure.cause, expected)
            XCTAssertFalse(failure.localizedDescription.contains(privateText))
            XCTAssertFalse(failure.diagnosticFields.values.joined().contains(privateText))
        }
    }

    func testOrdinaryForegroundStagePreservesOriginalError() {
        let original = NSError(domain: "fixture", code: 42)
        XCTAssertThrowsError(try performForegroundClickStage(.activation, authorization: nil) {
            throw original
        }) { error in
            XCTAssertTrue((error as NSError) === original)
        }
    }

    func testFailureCorrelatesWithoutLoggingErrorContentAndDoesNotReplay() throws {
        let collector = DiagnosticCollector()
        var attempts = 0
        let result = InputDiagnostics.$observer.withValue({ collector.append($0) }) {
            InputDiagnostics.result {
                try InputDiagnostics.input(route: .skyClick, point: CGPoint(x: -100, y: 400)) {
                    attempts += 1
                    throw ComputerUseError.message("private-window-title-and-message")
                }
                return .text("unexpected")
            }
        }
        let metadata = try XCTUnwrap((result["_meta"] as? [String: Any])?["ocuDiagnostic"] as? [String: String])
        XCTAssertEqual(metadata["status"], "failed")
        XCTAssertNotNil(metadata["id"].flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(collector.records.count, 6)
        XCTAssertTrue(collector.records.contains { $0.contains("tool_begin") && $0.contains("foreground_pid") })
        XCTAssertTrue(collector.records.contains { $0.contains("tool_end") && $0.contains("pointer") })
        for record in collector.records {
            XCTAssertTrue(try record.contains(XCTUnwrap(metadata["id"])))
            XCTAssertFalse(record.contains("private-window-title-and-message"))
        }
        XCTAssertTrue(collector.records.contains { $0.contains("input_failed") && $0.contains("unknown") })
        XCTAssertFalse(collector.records.contains { $0.contains("input_returned") })
        XCTAssertNil(InputDiagnostics.operationID)
    }

    func testReturnOnlyMeansUnverifiedAndIDsArePerCall() throws {
        let collector = DiagnosticCollector()
        let first = InputDiagnostics.$observer.withValue({ collector.append($0) }) {
            InputDiagnostics.result {
                try InputDiagnostics.input(route: .appPost, point: .zero) {}
                return .text("UI content must not be logged")
            }
        }
        let second = InputDiagnostics.result { .text("another call") }
        let firstMeta = try XCTUnwrap((first["_meta"] as? [String: Any])?["ocuDiagnostic"] as? [String: String])
        let secondMeta = try XCTUnwrap((second["_meta"] as? [String: Any])?["ocuDiagnostic"] as? [String: String])
        XCTAssertEqual(firstMeta["status"], "returned")
        XCTAssertNotEqual(firstMeta["id"], secondMeta["id"])
        XCTAssertTrue(collector.records.contains { $0.contains("input_returned") && $0.contains("unverified") })
        XCTAssertFalse(collector.records.joined().contains("UI content"))
    }

    func testKeyboardFailuresIncludeDiagnosticsWithoutLoggingTextOrKeys() throws {
        for name in ["type_text", "press_key"] {
            let collector = DiagnosticCollector()
            let request: [String: Any] = [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": name, "arguments": ["text": "private draft", "key": "private key"]],
            ]
            let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: request), encoding: .utf8))
            let response = InputDiagnostics.$observer.withValue({ collector.append($0) }) { StdioMCPServer().handle(line: json) }
            let bytes = try XCTUnwrap(response?.data(using: .utf8))
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertNotNil((result["_meta"] as? [String: Any])?["ocuDiagnostic"])
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertFalse(collector.records.joined().contains("private"))
        }
    }

    func testMCPErrorStillIncludesDiagnosticReference() throws {
        let server = StdioMCPServer()
        let request = #"{"jsonrpc":"2.0","id":"sensitive-client-id","method":"tools/call","params":{"name":"click","arguments":{}}}"#
        let collector = DiagnosticCollector()
        let response = InputDiagnostics.$observer.withValue({ collector.append($0) }) { server.handle(line: request) }
        let bytes = try XCTUnwrap(response?.data(using: .utf8))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNotNil((result["_meta"] as? [String: Any])?["ocuDiagnostic"])
        XCTAssertFalse(collector.records.joined().contains("sensitive-client-id"))
    }
}
