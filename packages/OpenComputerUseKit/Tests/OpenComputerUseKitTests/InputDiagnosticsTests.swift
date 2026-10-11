import Foundation
import XCTest
@testable import OpenComputerUseKit

private final class DiagnosticCollector: @unchecked Sendable {
    // 测试观察器可能跨线程调用，所有访问都由同一把锁保护。
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var records: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class InputDiagnosticsTests: XCTestCase {
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
        XCTAssertEqual(collector.records.count, 4)
        for record in collector.records {
            XCTAssertTrue(record.contains(try XCTUnwrap(metadata["id"])))
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
                "params": ["name": name, "arguments": ["text": "private draft", "key": "private key"]]
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
