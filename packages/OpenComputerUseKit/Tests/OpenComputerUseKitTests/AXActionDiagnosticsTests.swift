import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

private final class AXActionLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(text)
    }

    func records() throws -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return try storage.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
        }
    }

    func observe<T>(_ body: () throws -> T) rethrows -> T {
        try InputDiagnostics.$observer.withValue({ self.append($0) }, operation: body)
    }

    func scoped<T>(_ body: () throws -> T) rethrows -> T {
        try observe { try InputDiagnostics.$operationID.withValue("test-operation", operation: body) }
    }
}

final class AXActionDiagnosticsTests: XCTestCase {
    func testActualAttemptAndReturnBracketEachSubmissionIncludingFailure() throws {
        let collector = AXActionLogCollector()
        var sends = 0
        XCTAssertThrowsError(try collector.scoped {
            try executeAXAction(
                named: "AXPress", availableActions: ["AXPress"], repeatCount: 3,
                perform: {
                    sends += 1
                    // 调用体执行时只能看到本次 attempt，不能提前出现 returned。
                    let events = (try? collector.records()) ?? []
                    XCTAssertEqual(events.count, sends * 2 - 1)
                    XCTAssertEqual(events.last?["event"], "input_attempt")
                    XCTAssertEqual(events.last?["attempt"], String(sends))
                    return sends == 1 ? .success : .failure
                }, pauseBetweenAttempts: {}
            )
        }) { XCTAssertTrue($0.localizedDescription.contains("attempt 2/3 after 1 successful AX returns")) }
        XCTAssertEqual(sends, 2)
        let events = try collector.records()
        XCTAssertEqual(
            events.map { $0["event"] },
            ["input_attempt", "input_returned", "input_attempt", "input_returned"]
        )
        XCTAssertEqual(events.map { $0["attempt"] }, ["1", "1", "2", "2"])
        XCTAssertEqual(events[1]["ax_result"], "0")
        XCTAssertEqual(events[1]["effect"], "unverified")
        XCTAssertEqual(events[3]["ax_result"], String(AXError.failure.rawValue))
        XCTAssertEqual(events[3]["effect"], "unknown")
    }

    func testUndeclaredAndRejectedPreflightDoNotEmitAttempts() throws {
        let collector = AXActionLogCollector()
        let result = try collector.scoped {
            try executeAXAction(named: "AXPress", availableActions: [], perform: {
                XCTFail("未声明不得发送"); return .success
            })
        }
        XCTAssertEqual(result, .notAttempted)
        let original = NSError(domain: "preflight", code: 7)
        XCTAssertThrowsError(try collector.scoped {
            try executeAXAction(
                named: "AXPress", availableActions: ["AXPress"], preflight: { throw original },
                prepare: { XCTFail("预检失败不得准备") },
                perform: { XCTFail("预检失败不得发送"); return .success }
            )
        }) { XCTAssertTrue(($0 as NSError) === original) }
        XCTAssertTrue(try collector.records().isEmpty)
    }

    func testAllReturnedErrorsAreLoggedWithoutChangingStopBehavior() throws {
        for error: AXError in [
            .failure, .illegalArgument, .invalidUIElement, .invalidUIElementObserver, .cannotComplete,
            .attributeUnsupported, .actionUnsupported, .notificationUnsupported, .notImplemented,
            .notificationAlreadyRegistered, .notificationNotRegistered, .apiDisabled, .noValue,
            .parameterizedAttributeUnsupported, .notEnoughPrecision
        ] {
            let collector = AXActionLogCollector()
            var sends = 0
            XCTAssertThrowsError(try collector.scoped {
                try executeAXAction(
                    named: "AXPress", availableActions: ["AXPress"], repeatCount: 2,
                    perform: { sends += 1; return error },
                    pauseBetweenAttempts: { XCTFail("失败不得继续等待或重放") }
                )
            }) { XCTAssertTrue($0.localizedDescription.contains("returned \(error.rawValue) on attempt 1/2")) }
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(try collector.records().count, 2)
            XCTAssertEqual(try collector.records().last?["ax_result"], String(error.rawValue))
        }
    }

    func testActionRoleAndCandidateMetadataAreStrictlySanitized() throws {
        let actions = [
            "aXpReSs": "press", "AXConfirm": "confirm", "AXOpen": "open",
            "AXShowMenu": "show_menu", "AXRaise": "raise", "private-custom-action": "other"
        ]
        for route in AXActionDiagnosticContext.Route.allCases {
            for source in AXActionDiagnosticContext.Source.allCases {
                for (action, expected) in actions {
                    let collector = AXActionLogCollector()
                    let context = AXActionDiagnosticContext(
                        route: route, source: source, role: "private-custom-role", originalIndex: 39
                    )
                    XCTAssertEqual(collector.scoped {
                        context.perform(action: action, attempt: 1) { .success }
                    }, .success)
                    for event in try collector.records() {
                        XCTAssertEqual(event["route"], route.rawValue)
                        XCTAssertEqual(event["source"], source.rawValue)
                        XCTAssertEqual(event["action"], expected)
                        XCTAssertEqual(event["role"], "other")
                        XCTAssertEqual(event["original_index"], "39")
                        XCTAssertFalse(event.values.contains { $0.contains("private-") })
                    }
                }
            }
        }
    }

    func testMissingContextDoesNotSuppressActualActionOrInventMetadata() throws {
        var sends = 0
        let collector = AXActionLogCollector()
        let result = try collector.observe {
            try executeAXAction(named: "AXPress", availableActions: ["AXPress"], perform: {
                sends += 1; return .success
            })
        }
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(sends, 1)
        XCTAssertTrue(try collector.records().isEmpty)
        _ = collector.scoped {
            AXActionDiagnosticContext(originalIndex: -1).perform(action: "AXPress", attempt: 1) { .success }
        }
        XCTAssertEqual(try collector.records().first?["role"], "unknown")
        XCTAssertNil(try collector.records().first?["original_index"])
    }
}

final class AXActionDiagnosticsServiceTests: XCTestCase {
    private var previousEnvironment: [String: String] = [:]
    private let keys = ["OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_VISUAL_CURSOR"]

    override func setUp() {
        super.setUp()
        for key in keys {
            previousEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "0", 1)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = previousEnvironment[key] { setenv(key, value, 1) } else { unsetenv(key) }
        }
        super.tearDown()
    }

    private func service(actions: [String], backend: @escaping (AXUIElement, String) -> AXError) -> ComputerUseService {
        let app = RunningAppDescriptor(
            name: "Test",
            bundleIdentifier: "test.ax-diagnostics",
            pid: getpid(),
            runningApplication: .current
        )
        // 不绑定真实应用；最终 AX 输入由注入闭包接收，不操作 GUI。
        let record = ElementRecord(
            index: 39, identifier: nil, element: AXUIElementCreateApplication(-1),
            localFrame: CGRect(x: 10, y: 10, width: 60, height: 20), role: kAXButtonRole,
            rawActions: actions, prettyActions: []
        )
        let snapshot = AppSnapshot(
            app: app, windowTitle: nil, windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetWindowID: nil, targetWindowLayer: nil, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: [39: record]
        )
        return ComputerUseService(
            snapshots: ["test.ax-diagnostics": snapshot], snapshotDependencies: .live, axActionBackend: backend
        )
    }

    private func call(
        _ name: String, service: ComputerUseService, collector: AXActionLogCollector, extra: [String: Any] = [:]
    ) throws -> [String: Any] {
        var arguments: [String: Any] = ["app": "test.ax-diagnostics", "element_index": 39]
        arguments.merge(extra) { _, new in new }
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        // 由真实 MCP 包装建立 TaskLocal；测试不得手工补 operationID 掩盖缺失的入口包装。
        let reply = collector.observe { StdioMCPServer(service: service).handle(line: line) }
        let bytes = try XCTUnwrap(reply?.data(using: .utf8))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    func testClickMCPEntryCorrelatesActualActionAndPreservesSuccessOrFailure() throws {
        for error: AXError in [.success, .failure, .apiDisabled] {
            let collector = AXActionLogCollector()
            var actions: [String] = []
            let service = service(actions: ["AXPress", "AXConfirm", "AXOpen"]) { _, action in
                actions.append(action); return error
            }
            let result = try call("click", service: service, collector: collector)
            XCTAssertEqual(actions, ["AXPress"])
            try verify(result, collector: collector, tool: "click", route: "ax_action", error: error)
            if error != .success {
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                XCTAssertTrue(try XCTUnwrap(content.first?["text"] as? String).contains("effect is unknown"))
            }
        }
    }

    func testSecondaryMCPEntryAddsContextWithoutChangingCustomActionOrError() throws {
        for error: AXError in [.success, .failure, .apiDisabled] {
            let collector = AXActionLogCollector()
            var actions: [String] = []
            let customAction = "private-custom-action"
            let service = service(actions: [customAction]) { _, action in
                actions.append(action); return error
            }
            let result = try call(
                "perform_secondary_action", service: service, collector: collector, extra: ["action": customAction]
            )
            XCTAssertEqual(actions, [customAction])
            try verify(
                result,
                collector: collector,
                tool: "perform_secondary_action",
                route: "ax_secondary",
                error: error
            )
            XCTAssertFalse(try collector.records().flatMap(\.values).contains { $0.contains(customAction) })
            XCTAssertEqual(try collector.records().first { $0["event"] == "input_attempt" }?["action"], "other")
            if error != .success {
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                XCTAssertEqual(
                    content.first?["text"] as? String,
                    "AXUIElementPerformAction failed with \(error.rawValue)"
                )
            }
        }
    }

    func testSecondaryRejectedBeforeSubmissionStillHasMetadataButNoAttempt() throws {
        let collector = AXActionLogCollector()
        let service = service(actions: []) { _, _ in XCTFail("拒绝的动作不得发送"); return .success }
        let result = try call(
            "perform_secondary_action", service: service, collector: collector, extra: ["action": "unavailable"]
        )
        let meta = try XCTUnwrap((result["_meta"] as? [String: Any])?["ocuDiagnostic"] as? [String: String])
        XCTAssertEqual(meta["status"], "failed")
        XCTAssertEqual(meta["tool"], "perform_secondary_action")
        XCTAssertFalse(try collector.records().contains { $0["event"] == "input_attempt" })
        XCTAssertTrue(try collector.records().allSatisfy { $0["diagnostic_id"] == meta["id"] })
        XCTAssertNil(InputDiagnostics.operationID)
    }

    private func verify(
        _ result: [String: Any], collector: AXActionLogCollector, tool: String, route: String, error: AXError
    ) throws {
        let meta = try XCTUnwrap((result["_meta"] as? [String: Any])?["ocuDiagnostic"] as? [String: String])
        XCTAssertNotNil(meta["id"].flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(meta["tool"], tool)
        XCTAssertEqual(meta["status"], error == .success ? "returned" : "failed")
        XCTAssertEqual(result["isError"] as? Bool == true, error != .success)
        let records = try collector.records()
        XCTAssertTrue(records.allSatisfy { $0["diagnostic_id"] == meta["id"] })
        let inputs = records.filter { $0["event"]?.hasPrefix("input_") == true }
        XCTAssertEqual(inputs.map { $0["event"] }, ["input_attempt", "input_returned"])
        for event in inputs {
            XCTAssertEqual(event["route"], route)
            XCTAssertEqual(event["source"], "original")
            XCTAssertEqual(event["role"], "AXButton")
            XCTAssertEqual(event["original_index"], "39")
            XCTAssertEqual(event["attempt"], "1")
        }
        XCTAssertEqual(inputs.last?["ax_result"], String(error.rawValue))
        XCTAssertEqual(inputs.last?["effect"], error == .success ? "unverified" : "unknown")
        XCTAssertNil(InputDiagnostics.operationID)
    }
}
