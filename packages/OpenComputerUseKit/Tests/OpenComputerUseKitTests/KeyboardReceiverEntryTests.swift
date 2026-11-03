import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class KeyboardReceiverEntryTests: XCTestCase {
    private var oldReadBack: String?

    override func setUp() {
        super.setUp()
        oldReadBack = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_ACTION_READ_BACK"]
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0", 1)
    }

    override func tearDown() {
        if let oldReadBack {
            setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", oldReadBack, 1)
        } else {
            unsetenv("OPEN_COMPUTER_USE_ACTION_READ_BACK")
        }
        super.tearDown()
    }

    private func snapshot() -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(
                name: "Editor",
                bundleIdentifier: "test.editor",
                pid: getpid(),
                runningApplication: .current
            ),
            windowTitle: "Test", windowBounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            targetWindowID: 42, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: AXUIElementCreateApplication(123),
            selectedText: nil, windowElement: nil, elements: [:]
        )
    }

    func testMCPReturnUsesBoundedReceiverCheckAndNeverReplays() throws {
        for scenario in [
            "slow-success", "cannot-complete", "permission", "changed-window",
            "unknown-delivery", "timeout", "cancelled"
        ] {
            let expected = AXUIElementCreateApplication(123)
            var clock = 0.0
            var effectiveTimeout: Float = 0.1
            var reads = 0
            var sends = 0
            var cleanups = 0
            let backend = KeyboardInputBackend(
                readReceiver: { _, editable in
                    XCTAssertFalse(editable)
                    let reader = KeyboardReceiverAXReader(now: { clock }, checkCancellation: {
                        if scenario == "cancelled", reads > 0 { throw CancellationError() }
                    }, setTimeout: { _, timeout in
                        effectiveTimeout = timeout == 0 ? 0.1 : timeout
                        return .success
                    }, copyValue: { _, attribute in
                        XCTAssertEqual(attribute, kAXFocusedWindowAttribute)
                        reads += 1
                        clock += scenario == "timeout" ? 2.1 : 0.15
                        if scenario == "permission" { return (.apiDisabled, nil) }
                        if scenario == "cannot-complete" || effectiveTimeout <= 0.15 { return (.cannotComplete, nil) }
                        return (.success, scenario == "changed-window" ? AXUIElementCreateApplication(456) : expected)
                    })
                    let current = try reader.element(expected, attribute: kAXFocusedWindowAttribute)
                    try requireSameKeyboardReceiver(expected, current: current)
                    return current
                },
                typeText: { _, _, _ in XCTFail("must not fall back to typing") },
                pressKey: { _, key, validate in
                    XCTAssertEqual(key, "Return")
                    try withSkyKeyboardFocus(begin: { 1 }, prepare: { _ in }, deliver: {
                        try validate()
                        sends += 1
                        if scenario == "unknown-delivery" { throw ComputerUseError.message("effect unknown") }
                    }, end: { _ in cleanups += 1 })
                }
            )
            let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
            let result = try callReturn(service)
            XCTAssertEqual(result["isError"] as? Bool == true, scenario != "slow-success", scenario)
            XCTAssertEqual(reads, 1, scenario)
            XCTAssertEqual(sends, ["slow-success", "unknown-delivery"].contains(scenario) ? 1 : 0, scenario)
            XCTAssertEqual(cleanups, 1, scenario)
            XCTAssertEqual(effectiveTimeout, 0.1)
            XCTAssertNotNil((result["_meta"] as? [String: Any])?["ocuDiagnostic"])
        }
    }

    private func callReturn(_ service: ComputerUseService) throws -> [String: Any] {
        let server = StdioMCPServer(service: service, backgroundStateReset: {})
        let request = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
          "name":"press_key","arguments":{"app":"editor","key":"Return"}
        }}
        """
        let response = try XCTUnwrap(server.handle(line: request))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }
}
