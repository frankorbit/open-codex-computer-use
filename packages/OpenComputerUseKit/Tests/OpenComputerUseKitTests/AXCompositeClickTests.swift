import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXCompositeClickTests: XCTestCase {
    private let frame = CGRect(x: 20, y: 20, width: 400, height: 100)
    private let toggleHelp = "To mark as completed, press Control-Option-Space."

    private func node(_ role: String, help: String? = nil, frame: CGRect? = nil) -> ElementRecord {
        ElementRecord(index: 7, identifier: nil, element: nil, localFrame: frame ?? self.frame,
                      role: role, title: "Mark as completed", help: help,
                      rawActions: [kAXPressAction], prettyActions: [])
    }

    func testWholeCellCannotImplicitlyPressCompletionGroup() {
        let cell = node("AXCell")
        let group = node("AXGroup", help: toggleHelp)
        var sent = 0
        XCTAssertThrowsError(try {
            try validateAXCompositeClick(cell, button: .left) { parent, _ in parent.role == "AXCell" ? [group] : [] }
            sent += 1
        }()) { XCTAssertTrue($0.localizedDescription.contains("AX_INPUT_PREFLIGHT")) }
        XCTAssertEqual(sent, 0)
    }

    func testDirectControlsAndContextMenuRetainTheirSemantics() throws {
        for role in ["AXButton", "AXCheckBox", "AXMenuItem", "AXTextField", "AXPopUpButton", "AXSwitch"] {
            try validateAXCompositeClick(node(role, help: toggleHelp), button: .left) { _, _ in
                XCTFail("明确控件不得扫描子项"); return []
            }
        }
        try validateAXCompositeClick(node("AXGroup", help: toggleHelp), button: .right) { _, _ in [] }
        try validateAXCompositeClick(node("AXGroup"), button: .left) { _, _ in [] }
    }

    func testCompactCheckboxOrUnrelatedSiblingDoesNotBlockRow() throws {
        let children = [node("AXCheckBox", help: toggleHelp),
                        node("AXGroup", help: toggleHelp, frame: CGRect(x: 20, y: 20, width: 18, height: 18)),
                        node("AXGroup", help: toggleHelp, frame: CGRect(x: 800, y: 20, width: 400, height: 100))]
        try validateAXCompositeClick(node("AXRow"), button: .left) { _, _ in children }
    }

    func testHelpSupportsBothStatesAndDoesNotInferActionFromUserTitle() throws {
        let cases = [toggleHelp, "To mark as incomplete, press Control-Option-Space.", "按下以标记为已完成", "标记为未完成"]
        for help in cases {
            let target = node("AXGroup", help: help)
            XCTAssertThrowsError(try validateAXCompositeClick(target, button: .left) { _, _ in [] })
        }
        try validateAXCompositeClick(node("AXCell", help: "Open details"), button: .left) { _, _ in [] }
    }

    func testTraversalIsBoundedAndPropagatesReadFailuresBeforeInput() {
        var calls = 0
        XCTAssertNoThrow(try validateAXCompositeClick(node("AXCell"), button: .left) { _, _ in
            calls += 1
            return Array(repeating: self.node("AXGroup"), count: 100)
        })
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try validateAXCompositeClick(node("AXCell"), button: .left) { _, _ in
            throw ComputerUseError.permissionDenied("permission denied")
        })
    }

    func testRemainingBudgetReachesReaderBeforeFetchingChildren() throws {
        var limits: [Int] = []
        try validateAXCompositeClick(node("AXCell"), button: .left) { _, limit in
            limits.append(limit)
            return Array(repeating: self.node("AXGroup"), count: limits.count == 1 ? 2 : limit)
        }
        XCTAssertEqual(limits, [32, 30])
    }

    func testServiceClickRejectsAmbiguousCompositeBeforeAnyInputRoute() throws {
        let record = node("AXGroup", help: toggleHelp)
        let app = RunningAppDescriptor(
            name: "Test Editor",
            bundleIdentifier: "test.editor",
            pid: getpid(),
            runningApplication: .current
        )
        let snapshot = AppSnapshot(app: app, windowTitle: nil, windowBounds: frame,
                                   targetWindowID: nil, targetWindowLayer: nil, screenshotData: nil,
                                   mode: .accessibility, treeLines: [], focusedSummary: nil,
                                   focusedElement: nil, selectedText: nil, windowElement: nil, elements: [7: record])
        let service = ComputerUseService(
            snapshots: ["test.editor": snapshot],
            coordinateClickBackend: CoordinateClickBackend(
                validateWindow: { _, _ in XCTFail("不得进入坐标校验") },
                hitTest: { _, _ in XCTFail("不得重新命中其他控件"); return nil },
                performMouse: { _, _, _, _ in XCTFail("不得发送鼠标输入") }
            )
        )
        // 真实 service 入口；预检必须早于 AX、鼠标和动作回读，不能因拒绝改走其他路线。
        let click = {
            try service.click(app: "test.editor", elementIndex: "7", x: nil, y: nil,
                              clickCount: 1, mouseButton: "left")
        }
        XCTAssertThrowsError(try click()) {
            XCTAssertTrue($0.localizedDescription.contains("composite row/cell"))
            XCTAssertTrue($0.localizedDescription.contains("No input was sent"))
        }
        let compact = service.compactRecordDictionary(record)
        XCTAssertEqual(compact["help"] as? String, toggleHelp)
        XCTAssertEqual(compact["role"] as? String, "AXGroup")
    }
}
