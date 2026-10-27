import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXInputScopeTests: XCTestCase {
    private struct Node {
        var role: String
        var parent: Int?
        var children: [Int] = []
        var visible: Bool?
        var pid: pid_t = 42
    }

    private func graph() -> [Int: Node] {
        [0: Node(role: "AXApplication", parent: nil, children: [1, 10]),
         1: Node(role: "AXWindow", parent: 0, children: [2, 3]),
         2: Node(role: "AXTextField", parent: 1),
         3: Node(role: "AXPopover", parent: 1, children: [4, 5]),
         4: Node(role: "AXTextField", parent: 3),
         5: Node(role: "AXSheet", parent: 3, children: [6]),
         6: Node(role: "AXTextField", parent: 5),
         10: Node(role: "AXWindow", parent: 0, children: [11]),
         11: Node(role: "AXPopover", parent: 10, children: [12]),
         12: Node(role: "AXTextField", parent: 11),
         20: Node(role: "AXMenu", parent: 1, children: [21]),
         21: Node(role: "AXMenuItem", parent: 20)]
    }

    private func reader(_ nodes: [Int: Node]) -> AXInputScopeReader<Int> {
        AXInputScopeReader(
            role: { nodes[$0]?.role },
            owner: { nodes[$0]?.pid },
            parent: { nodes[$0]?.parent },
            children: { nodes[$0]?.children ?? [] },
            visible: { nodes[$0]?.visible },
            equal: ==
        )
    }

    func testPopoverRejectsBackgroundFieldBeforePrepareAndWrite() {
        var writes = 0
        XCTAssertThrowsError(try executeAXScopedValueWrite(
            preflight: {
                try validateAXEditingScope(
                    target: 2,
                    observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: 4),
                    pid: 42,
                    reader: self.reader(self.graph())
                )
            }, prepare: { XCTFail("预检失败不得准备输入") }, perform: { writes += 1; return .success }
        )) { XCTAssertTrue($0.localizedDescription.contains("No input was sent")) }
        XCTAssertEqual(writes, 0)
    }

    func testCurrentPopoverAndNestedSheetAcceptOnlyTheirDescendants() throws {
        let probe = reader(graph())
        try validateAXEditingScope(
            target: 4,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: 4),
            pid: 42,
            reader: probe
        )
        try validateAXEditingScope(
            target: 6,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3, 5], focused: 6),
            pid: 42,
            reader: probe
        )
        XCTAssertThrowsError(try validateAXEditingScope(
            target: 4,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3, 5], focused: 6),
            pid: 42,
            reader: probe
        ))
    }

    func testLiveFocusFindsNewScopeEvenForQueryTargetWithNoRenderedScopes() {
        XCTAssertThrowsError(try validateAXEditingScope(
            target: 2,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [], focused: 4),
            pid: 42,
            reader: reader(graph())
        ))
    }

    func testPlainEditorAndOtherWindowRemainUsable() throws {
        let probe = reader(graph())
        try validateAXEditingScope(
            target: 2,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [], focused: 2),
            pid: 42,
            reader: probe
        )
        try validateAXEditingScope(
            target: 2,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [], focused: 12),
            pid: 42,
            reader: probe
        )
        try validateAXEditingScope(
            target: 2,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [], focused: nil),
            pid: 42,
            reader: probe
        )
    }

    func testDetachedChangedHiddenAndForeignScopes() throws {
        var nodes = graph()
        nodes[1]?.children = [2]
        XCTAssertThrowsError(try validateAXEditingScope(
            target: 4,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
            pid: 42,
            reader: reader(nodes)
        ))
        nodes = graph(); nodes[3]?.role = "AXGroup"
        XCTAssertThrowsError(try validateAXEditingScope(
            target: 4,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
            pid: 42,
            reader: reader(nodes)
        ))
        nodes = graph(); nodes[3]?.visible = false
        try validateAXEditingScope(
            target: 2,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
            pid: 42,
            reader: reader(nodes)
        )
        nodes = graph(); nodes[3]?.pid = 999
        XCTAssertThrowsError(try validateAXEditingScope(
            target: 4,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
            pid: 42,
            reader: reader(nodes)
        ))
    }

    func testUncertainReadsAndDeadlineNeverPermitWrite() {
        for error in [
            ComputerUseError.permissionDenied("Accessibility permission is required"),
            axInputPreflightFailure("timeout")
        ] {
            var probe = reader(graph())
            probe.checkDeadline = { throw error }
            XCTAssertThrowsError(try executeAXScopedValueWrite(preflight: {
                try validateAXEditingScope(
                    target: 4,
                    observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
                    pid: 42,
                    reader: probe
                )
            }, prepare: {}, perform: { XCTFail("不明状态不可写入"); return .success })) {
                XCTAssertEqual($0.localizedDescription, error.localizedDescription)
            }
        }
        var nodes = graph(); nodes[3]?.parent = 3
        XCTAssertThrowsError(try validateAXEditingScope(
            target: 4,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
            pid: 42,
            reader: reader(nodes)
        ))
    }

    func testMenuPreflightRejectsStaleHiddenReparentedAndForeignTargetsWithoutFallback() {
        var cases: [[Int: Node]] = []
        var nodes = graph(); nodes[21] = nil; cases.append(nodes)
        nodes = graph(); nodes[20]?.children = []; cases.append(nodes)
        nodes = graph(); nodes[21]?.parent = 1; cases.append(nodes)
        nodes = graph(); nodes[20]?.visible = false; cases.append(nodes)
        nodes = graph(); nodes[21]?.pid = 999; cases.append(nodes)
        nodes = graph(); nodes[21]?.role = "AXButton"; cases.append(nodes)
        for nodes in cases {
            var calls: [String] = []
            XCTAssertThrowsError(try executeAXAction(
                named: "AXPress",
                availableActions: ["AXPress"],
                preflight: { try validateAXMenuItem(
                    21,
                    pid: 42,
                    reader: self.reader(nodes)
                ) },
                prepare: { calls.append("prepare") },
                perform: { calls.append("press"); return .success }
            ))
            XCTAssertEqual(calls, [])
        }
    }

    func testMenuItemInsideGroupIsValidWithoutChangingPlainActions() throws {
        var nodes = graph()
        nodes[20]?.children = [22]
        nodes[22] = Node(role: "AXGroup", parent: 20, children: [21])
        nodes[21]?.parent = 22
        try validateAXMenuItem(21, pid: 42, reader: reader(nodes))
        var calls = 0
        XCTAssertEqual(try executeAXAction(
            named: "AXPress",
            availableActions: ["AXPress"],
            perform: { calls += 1; return .success }
        ), .completed)
        XCTAssertEqual(calls, 1)
    }

    func testMenuValidBeforeSendButInvalidAtAXPressIsNotRetried() {
        var calls = 0
        XCTAssertThrowsError(try executeAXAction(
            named: "AXPress",
            availableActions: ["AXPress"],
            repeatCount: 3,
            preflight: { try validateAXMenuItem(
                21,
                pid: 42,
                reader: self.reader(self.graph())
            ) },
            perform: { calls += 1; return .invalidUIElement }
        )) {
            XCTAssertTrue($0.localizedDescription.contains("effect is unknown"))
        }
        XCTAssertEqual(calls, 1)
    }

    func testValueWriteReturnsOnceAndKeepsUnknownEffectOnFailure() throws {
        for result in [AXError.success, .cannotComplete, .invalidUIElement, .apiDisabled] {
            var events: [String] = []
            let write = {
                try executeAXScopedValueWrite(
                    preflight: { events.append("validate") },
                    prepare: { events.append("prepare") },
                    perform: { events.append("write"); return result }
                )
            }
            if result == .success { try write() } else {
                XCTAssertThrowsError(try write()) {
                    XCTAssertTrue($0.localizedDescription.contains("effect is unknown"))
                }
            }
            XCTAssertEqual(events, ["validate", "prepare", "write"])
        }
    }
}

extension AXInputScopeTests {
    func testDetachedTargetCannotBorrowAnOldPopoverParent() {
        var nodes = graph()
        nodes[3]?.children = [5]
        XCTAssertThrowsError(try validateAXEditingScope(
            target: 4,
            observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
            pid: 42,
            reader: reader(nodes)
        ))
    }

    func testCancellationStopsBeforeEitherInput() {
        var probe = reader(graph())
        probe.checkDeadline = { throw CancellationError() }
        XCTAssertThrowsError(try executeAXScopedValueWrite(preflight: {
            try validateAXEditingScope(
                target: 4,
                observation: AXEditingScopeObservation(window: 1, observedScopes: [3], focused: nil),
                pid: 42,
                reader: probe
            )
        }, prepare: { XCTFail("取消后不得准备输入") }, perform: { XCTFail("取消后不得写值"); return .success })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try executeAXAction(named: "AXPress", availableActions: ["AXPress"], preflight: {
            try validateAXMenuItem(21, pid: 42, reader: probe)
        }, perform: { XCTFail("取消后不得点击"); return .success })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testRenderedEditorGuidancePreservesBackgroundAndIndexes() {
        func snapshot(_ roles: [String]) -> AppSnapshot {
            AppSnapshot(
                app: RunningAppDescriptor(
                    name: "Test",
                    bundleIdentifier: "test.scope",
                    pid: 42,
                    runningApplication: .current
                ),
                windowTitle: "Test",
                windowBounds: nil,
                targetWindowID: nil,
                targetWindowLayer: nil,
                screenshotData: nil,
                mode: .accessibility,
                treeLines: ["1: background field", "2: current editor"],
                focusedSummary: nil,
                focusedElement: nil,
                selectedText: nil,
                windowElement: nil,
                elements: Dictionary(uniqueKeysWithValues: roles.enumerated().map { index, role in
                    (
                        index + 1,
                        ElementRecord(
                            index: index + 1,
                            identifier: nil,
                            element: nil,
                            localFrame: nil,
                            role: role,
                            rawActions: [],
                            prettyActions: []
                        )
                    )
                })
            )
        }
        let scoped = snapshot(["AXTextField", "AXPopover"])
        XCTAssertTrue(scoped.renderedText.contains("Editing scope:"))
        XCTAssertTrue(scoped.renderedText.contains("1: background field"))
        XCTAssertTrue(scoped.renderedText.contains("2: current editor"))
        XCTAssertEqual(scoped.elements.count, 2)
        XCTAssertFalse(snapshot(["AXTextField", "AXGroup"]).renderedText.contains("Editing scope:"))
    }
}
