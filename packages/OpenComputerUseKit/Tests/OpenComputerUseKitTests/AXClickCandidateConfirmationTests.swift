import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

private final class CandidateDiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(text)
    }

    func events() throws -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return try storage.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
        }
    }
}

final class AXClickCandidateConfirmationTests: XCTestCase {
    private var previousEnvironment: [String: String] = [:]
    private let keys = ["OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_VISUAL_CURSOR"]
    private let rootElement = AXUIElementCreateApplication(-11)
    private let textElement = AXUIElementCreateApplication(-12)
    private let buttonElement = AXUIElementCreateApplication(-13)
    private let rootFrame = CGRect(x: 10, y: 10, width: 300, height: 44)
    private let textFrame = CGRect(x: 115, y: 12, width: 90, height: 40)
    private let buttonFrame = CGRect(x: 20, y: 12, width: 110, height: 40)

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

    private func record(
        _ element: AXUIElement, role: String?, actions: [String], frame: CGRect, index: Int = -1
    ) -> ElementRecord {
        ElementRecord(index: index, identifier: nil, element: element, localFrame: frame,
                      role: role, rawActions: actions, prettyActions: [])
    }

    private func root(role: String? = "AXRow", actions: [String] = []) -> ElementRecord {
        record(rootElement, role: role, actions: actions, frame: rootFrame, index: 18)
    }

    private func service(
        root: ElementRecord, extra: [ElementRecord] = [],
        candidates: @escaping (AXUIElement) -> [ElementRecord],
        perform: @escaping (AXUIElement, String) -> AXError
    ) -> ComputerUseService {
        // 无效 PID 禁止接触真实应用；命中分支只使用已有几何缓存，最终输入由闭包接收。
        let app = RunningAppDescriptor(name: "Test", bundleIdentifier: "test.candidate-confirm", pid: -1,
                                       runningApplication: .current)
        let snapshot = AppSnapshot(
            app: app, windowTitle: nil, windowBounds: CGRect(x: 0, y: 0, width: 400, height: 100),
            targetWindowID: nil, targetWindowLayer: nil, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: Dictionary(uniqueKeysWithValues: ([root] + extra).map { ($0.index, $0) })
        )
        return ComputerUseService(
            snapshots: ["test.candidate-confirm": snapshot], snapshotDependencies: .live,
            axActionBackend: perform, descendantCandidatesBackend: candidates
        )
    }

    private func click(
        _ service: ComputerUseService, log: CandidateDiagnosticLog,
        method: ClickMethod = .auto, button: String = "left", count: Int = 1
    ) -> [String: Any] {
        let observer: @Sendable (String) -> Void = { log.append($0) }
        return InputDiagnostics.$observer.withValue(observer) {
            InputDiagnostics.result {
                try service.click(app: "test.candidate-confirm", elementIndex: "18", x: nil, y: nil,
                                  clickCount: count, mouseButton: button, clickMethod: method)
            }
        }
    }

    func testDescendantTextConfirmIsSkippedBeforeOneValidButtonPress() throws {
        for method in [ClickMethod.auto, .accessibility] {
            let text = record(textElement, role: "AXTextField", actions: ["AXConfirm"], frame: textFrame)
            let button = record(buttonElement, role: "AXButton", actions: ["AXPress"], frame: buttonFrame)
            let log = CandidateDiagnosticLog()
            var actions: [String] = []
            var scans = 0
            let service = service(root: root(), candidates: { _ in
                scans += 1
                // 反序输入；生产排序会先尝试面积更小的文本框，不能由测试提前排除它。
                return [button, text]
            }, perform: { element, action in
                XCTAssertTrue(CFEqual(element, self.buttonElement))
                actions.append(action); return .success
            })
            XCTAssertFalse(click(service, log: log, method: method)["isError"] as? Bool == true)
            XCTAssertEqual(scans, 1)
            XCTAssertEqual(actions, ["AXPress"])
            let attempts = try log.events().filter { $0["event"] == "input_attempt" }
            XCTAssertEqual(attempts.count, 1)
            XCTAssertEqual(attempts.first?["source"], "descendant")
            XCTAssertEqual(attempts.first?["action"], "press")
        }
    }

    func testOnlyTextConfirmDoesNotReportSuccessfulClickOrSendInput() throws {
        let text = record(textElement, role: "AXTextField", actions: ["AXConfirm"], frame: textFrame)
        let log = CandidateDiagnosticLog()
        let service = service(root: root(), candidates: { _ in [text] }, perform: { _, _ in
            XCTFail("被排除的 Confirm 不得发送"); return .success
        })
        XCTAssertEqual(click(service, log: log, method: .accessibility)["isError"] as? Bool, true)
        XCTAssertFalse(try log.events().contains { $0["event"] == "input_attempt" })
    }

    func testFailureAfterValidButtonPressStopsBeforeOtherActionsCandidatesOrMouse() throws {
        for error: AXError in [.failure, .cannotComplete, .apiDisabled, .actionUnsupported] {
            let text = record(textElement, role: "AXTextField", actions: ["AXConfirm"], frame: textFrame)
            let button = record(buttonElement, role: "AXButton", actions: ["AXPress", "AXConfirm", "AXOpen"],
                                frame: buttonFrame)
            let log = CandidateDiagnosticLog()
            var actions: [String] = []
            var scans = 0
            let service = service(root: root(), candidates: { _ in scans += 1; return [text, button] },
                                  perform: { element, action in
                                      XCTAssertTrue(CFEqual(element, self.buttonElement))
                                      actions.append(action); return error
                                  })
            let result = click(service, log: log)
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertEqual(actions, ["AXPress"])
            XCTAssertEqual(scans, 1)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertTrue(try XCTUnwrap(content.first?["text"] as? String).contains("returned \(error.rawValue)"))
            XCTAssertFalse(try log.events().contains { $0["event"] == "mouse_route_selected" })
            XCTAssertEqual(try log.events().count(where: { $0["event"] == "input_attempt" }), 1)
        }
    }

    func testTextFieldPressFailureStillStopsBeforeConfirmOtherCandidatesOrMouse() throws {
        let text = record(
            textElement,
            role: "AXTextField",
            actions: ["AXPress", "AXConfirm", "AXOpen"],
            frame: textFrame
        )
        let button = record(buttonElement, role: "AXButton", actions: ["AXPress"], frame: buttonFrame)
        let log = CandidateDiagnosticLog()
        var actions: [String] = []
        var scans = 0
        let service = service(root: root(), candidates: { _ in scans += 1; return [button, text] },
                              perform: { element, action in
                                  XCTAssertTrue(CFEqual(element, self.textElement))
                                  actions.append(action); return .failure
                              })
        XCTAssertEqual(click(service, log: log)["isError"] as? Bool, true)
        XCTAssertEqual(actions, ["AXPress"])
        XCTAssertEqual(scans, 1)
        XCTAssertFalse(try log.events().contains { $0["event"] == "mouse_route_selected" })
    }

    func testOriginalTextFieldConfirmRemainsAvailable() {
        var actions: [String] = []
        let service = service(root: root(role: "AXTextField", actions: ["AXConfirm"]), candidates: { _ in
            XCTFail("原目标成功后不得扫描候选"); return []
        }, perform: { _, action in actions.append(action); return .success })
        XCTAssertFalse(click(service, log: CandidateDiagnosticLog())["isError"] as? Bool == true)
        XCTAssertEqual(actions, ["AXConfirm"])
    }

    func testOtherAndUnknownRolesKeepConfirmAndTextFieldKeepsOtherActions() {
        let cases: [(String?, String)] = [
            (nil, "AXConfirm"), ("AXUnknown", "AXConfirm"), ("AXButton", "AXConfirm"),
            ("AXTextArea", "AXConfirm"), ("AXComboBox", "AXConfirm"),
            ("AXTextField", "AXPress"), ("AXTextField", "AXOpen")
        ]
        for (role, action) in cases {
            let candidate = record(textElement, role: role, actions: [action], frame: textFrame)
            var actions: [String] = []
            let service = service(root: root(), candidates: { _ in [candidate] }, perform: { _, action in
                actions.append(action); return .success
            })
            XCTAssertFalse(click(service, log: CandidateDiagnosticLog())["isError"] as? Bool == true)
            XCTAssertEqual(actions, [action])
        }
    }
}

extension AXClickCandidateConfirmationTests {
    func testSameAXObjectInDifferentDescendantRecordPreservesOriginalConfirm() throws {
        let duplicate = record(rootElement, role: "AXTextField", actions: ["AXConfirm"], frame: textFrame, index: 99)
        let log = CandidateDiagnosticLog()
        var actions: [String] = []
        let service = service(root: root(role: "AXTextField"), candidates: { _ in [duplicate] },
                              perform: { _, action in actions.append(action); return .success })
        XCTAssertFalse(click(service, log: log)["isError"] as? Bool == true)
        XCTAssertEqual(actions, ["AXConfirm"])
        let attempt = try log.events().first { $0["event"] == "input_attempt" }
        XCTAssertEqual(attempt?["source"], "descendant")
        XCTAssertEqual(attempt?["original_index"], "18")
    }

    func testHitTextConfirmAndHitDescendantTextConfirmAreSkippedBeforeButton() throws {
        let hit = record(textElement, role: "AXTextField", actions: ["AXConfirm"], frame: textFrame, index: 19)
        let innerText = record(AXUIElementCreateApplication(-14), role: "AXTextField", actions: ["AXConfirm"],
                               frame: textFrame)
        let button = record(buttonElement, role: "AXButton", actions: ["AXPress"], frame: buttonFrame)
        let log = CandidateDiagnosticLog()
        var scans = 0
        var actions: [String] = []
        let service = service(root: root(), extra: [hit], candidates: { element in
            scans += 1
            return CFEqual(element, self.textElement) ? [button, innerText] : []
        }, perform: { element, action in
            XCTAssertTrue(CFEqual(element, self.buttonElement))
            actions.append(action); return .success
        })
        XCTAssertFalse(click(service, log: log)["isError"] as? Bool == true)
        XCTAssertEqual(actions, ["AXPress"])
        XCTAssertEqual(scans, 2)
        let attempts = try log.events().filter { $0["event"] == "input_attempt" }
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?["source"], "hit_descendant")
    }

    func testHitOfOriginalAXObjectWithDifferentIndexPreservesConfirm() throws {
        let hit = record(rootElement, role: "AXTextField", actions: ["AXConfirm"], frame: textFrame, index: 19)
        let log = CandidateDiagnosticLog()
        var actions: [String] = []
        let service = service(root: root(role: "AXTextField"), extra: [hit], candidates: { _ in [] },
                              perform: { element, action in
                                  XCTAssertTrue(CFEqual(element, self.rootElement))
                                  actions.append(action); return .success
                              })
        XCTAssertFalse(click(service, log: log)["isError"] as? Bool == true)
        XCTAssertEqual(actions, ["AXConfirm"])
        XCTAssertEqual(try log.events().first { $0["event"] == "input_attempt" }?["source"], "hit")
    }

    func testRightDoubleAndMiddleClicksKeepExistingBehavior() {
        for (button, count, expected) in [
            ("left", 2, ["AXConfirm", "AXConfirm"]), ("right", 1, ["AXShowMenu"]), ("middle", 1, [])
        ] {
            let text = record(textElement, role: "AXTextField", actions: ["AXConfirm", "AXShowMenu"], frame: textFrame)
            var actions: [String] = []
            let service = service(root: root(), candidates: { _ in [text] }, perform: { _, action in
                actions.append(action); return .success
            })
            let result = click(
                service,
                log: CandidateDiagnosticLog(),
                method: .accessibility,
                button: button,
                count: count
            )
            XCTAssertEqual(result["isError"] as? Bool == true, button == "middle")
            XCTAssertEqual(actions, expected)
        }
    }

    func testExplicitSecondaryConfirmOnTextFieldIsUnchanged() throws {
        var actions: [String] = []
        let service = service(root: root(role: "AXTextField", actions: ["AXConfirm"]), candidates: { _ in
            XCTFail("secondary 不得扫描候选"); return []
        }, perform: { _, action in actions.append(action); return .success })
        _ = try service.performSecondaryAction(app: "test.candidate-confirm", elementIndex: "18", action: "AXConfirm")
        XCTAssertEqual(actions, ["AXConfirm"])
    }

    func testAdvertisedMenuCancelUsesOriginalTargetOnceAndNeverScansCandidates() throws {
        var actions: [String] = []
        let service = service(root: root(role: "AXMenu", actions: ["AXCancel", "AXPick"]), candidates: { _ in
            XCTFail("取消菜单不得扫描候选或转向父编辑器"); return []
        }, perform: { element, action in
            XCTAssertTrue(CFEqual(element, self.rootElement))
            actions.append(action)
            return .success
        })
        _ = try service.performSecondaryAction(app: "test.candidate-confirm", elementIndex: "18", action: "Cancel")
        XCTAssertEqual(actions, ["AXCancel"])
    }

    func testMenuCancelFailureIsNotRetriedAndMissingActionSendsNothing() {
        for failure: AXError? in [nil, .apiDisabled, .cannotComplete, .invalidUIElement] {
            var actions: [String] = []
            let advertised = failure == nil ? ["AXPick"] : ["AXCancel", "AXPick"]
            let service = service(root: root(role: "AXMenu", actions: advertised), candidates: { _ in
                XCTFail("失败不得转向另一个目标"); return []
            }, perform: { _, action in
                actions.append(action)
                return failure ?? .success
            })
            XCTAssertThrowsError(try service.performSecondaryAction(
                app: "test.candidate-confirm", elementIndex: "18", action: "Cancel",
            ))
            XCTAssertEqual(actions, failure == nil ? [] : ["AXCancel"])
        }
    }
}
