import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class KeyboardEscapeEntryTests: XCTestCase {
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

    func testAmbiguousEscapeStopsBeforeFocusPreparationForBothMethods() throws {
        for method in ["auto", "sky_key"] {
            var preparations = 0
            var checks = 0
            var backend = backendWithoutInput()
            backend.validateMenuEscape = { snapshot in
                XCTAssertTrue(KeyboardEscapeGuard.hasObservedMenu(snapshot))
                checks += 1
                try KeyboardEscapeGuard.validateFocusedRole(kAXTextAreaRole as String)
            }
            backend.pressKey = { _, _, _ in preparations += 1 }
            let result = try call(key: "Escape", method: method, backend: backend)
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertTrue(String(describing: result).contains("AX_INPUT_PREFLIGHT"))
            XCTAssertFalse(String(describing: result).contains("PERMISSION_DENIED"))
            XCTAssertEqual(checks, 1)
            XCTAssertEqual(preparations, 0)
        }
    }

    func testPreparedEscapeRevalidatesAndNeverFallsBackOrReplays() throws {
        for method in ["auto", "sky_key"] {
            for scenario in ["success", "changed-focus", "permission", "timeout", "cancelled", "unknown-delivery"] {
                var checks = 0
                var sends = 0
                var cleanups = 0
                var preparations = 0
                var windowChecks = 0
                var backend = backendWithoutInput()
                backend.readReceiver = { _, editable in
                    XCTAssertFalse(editable)
                    windowChecks += 1
                    return AXUIElementCreateApplication(123)
                }
                backend.validateWindow = { _ in windowChecks += 1 }
                backend.validateMenuEscape = { _ in
                    checks += 1
                    if checks > 1 {
                        try self.validatePreparedScenario(scenario)
                    }
                    try KeyboardEscapeGuard.validateFocusedRole(kAXMenuItemRole as String)
                }
                backend.pressKey = { _, key, validate in
                    XCTAssertEqual(key, "Esc")
                    preparations += 1
                    try withSkyKeyboardFocus(begin: { 1 }, prepare: { _ in }, deliver: {
                        try validate()
                        sends += 1
                        if scenario == "unknown-delivery" { throw ComputerUseError.message("effect unknown") }
                    }, end: { _ in cleanups += 1 })
                }
                let result = try call(key: "Esc", method: method, backend: backend)
                XCTAssertEqual(result["isError"] as? Bool == true, scenario != "success", scenario)
                if scenario == "permission" {
                    XCTAssertTrue(String(describing: result).contains("test permission"))
                }
                if scenario == "unknown-delivery" {
                    XCTAssertTrue(String(describing: result).contains("effect unknown"))
                }
                XCTAssertEqual(checks, 2, scenario)
                XCTAssertEqual(windowChecks, 1, scenario)
                XCTAssertEqual(preparations, 1, scenario)
                XCTAssertEqual(sends, ["success", "unknown-delivery"].contains(scenario) ? 1 : 0, scenario)
                XCTAssertEqual(cleanups, 1, scenario)
            }
        }
    }

    private func validatePreparedScenario(_ scenario: String) throws {
        switch scenario {
        case "changed-focus":
            try KeyboardEscapeGuard.validateFocusedRole(kAXTextAreaRole as String)
        case "permission": throw ComputerUseError.permissionDenied("test permission")
        case "timeout": throw ComputerUseError.message("receiver timed out")
        case "cancelled": throw CancellationError()
        default: break
        }
    }

    func testOrdinaryKeysDoNotInvokeMenuGuard() throws {
        for method in ["auto", "sky_key"] {
            for key in ["Return", "super+s", "shift+Escape", "Down"] {
                var sends = 0
                var backend = backendWithoutInput()
                backend.validateMenuEscape = { _ in XCTFail("ordinary key must not inspect menu focus") }
                backend.pressKey = { _, _, validate in
                    try validate()
                    sends += 1
                }
                let result = try call(key: key, method: method, backend: backend)
                XCTAssertNotEqual(result["isError"] as? Bool, true)
                XCTAssertEqual(sends, 1)
            }
        }
    }

    func testEscapeWithoutMenuKeepsExistingRouteWithoutMenuAXReads() throws {
        for method in ["auto", "sky_key"] {
            var sends = 0
            var backend = backendWithoutInput()
            // 默认 guard 面对无菜单快照必须立即返回；测试 PID 不依赖真实桌面焦点。
            backend.pressKey = { _, _, validate in
                try validate()
                sends += 1
            }
            let result = try call(key: "Escape", method: method, menu: false, backend: backend)
            XCTAssertNotEqual(result["isError"] as? Bool, true)
            XCTAssertEqual(sends, 1)
        }
    }

    private func backendWithoutInput() -> KeyboardInputBackend {
        var backend = KeyboardInputBackend(
            readReceiver: { _, _ in AXUIElementCreateApplication(123) },
            typeText: { _, _, _ in XCTFail("must not fall back to typing") },
            pressKey: { _, _, _ in XCTFail("must not send input") }
        )
        backend.validateWindow = { _ in }
        backend.pasteText = { _, _, _, _ in XCTFail("must not fall back to paste") }
        return backend
    }

    private func call(
        key: String, method: String, menu: Bool = true, backend: KeyboardInputBackend
    ) throws -> [String: Any] {
        let snapshot = escapeTestSnapshot(records: menu ? [
            escapeTestRecord(1, role: kAXMenuBarItemRole as String, selection: .init(selected: true as NSNumber))
        ] : [])
        let service = ComputerUseService(snapshots: ["editor": snapshot], keyboardInputBackend: backend)
        let server = StdioMCPServer(service: service, backgroundStateReset: {})
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "press_key", "arguments": ["app": "editor", "key": key, "key_method": method]]
        ])
        let request = try XCTUnwrap(String(data: data, encoding: .utf8))
        let response = try XCTUnwrap(server.handle(line: request))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }
}

func escapeTestRecord(
    _ index: Int, role: String, selection: TargetedSelectionState = .init()
) -> ElementRecord {
    ElementRecord(
        index: index, identifier: nil, element: nil, localFrame: nil, role: role,
        rawActions: [], prettyActions: [], selectionState: selection
    )
}

func escapeTestSnapshot(records: [ElementRecord]) -> AppSnapshot {
    AppSnapshot(
        app: RunningAppDescriptor(name: "Editor", bundleIdentifier: "test.editor", pid: getpid(),
                                  runningApplication: .current),
        windowTitle: "Test", windowBounds: CGRect(x: 0, y: 0, width: 600, height: 400),
        targetWindowID: 42, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
        treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
        elements: Dictionary(uniqueKeysWithValues: records.map { ($0.index, $0) })
    )
}
