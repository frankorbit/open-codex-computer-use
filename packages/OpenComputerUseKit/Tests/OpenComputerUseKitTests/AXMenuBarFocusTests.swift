import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXMenuBarFocusTests: XCTestCase {
    private var previous: [String: String] = [:]
    private let keys = ["OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_VISUAL_CURSOR"]

    override func setUp() {
        super.setUp()
        for key in keys {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "0", 1)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
        }
        super.tearDown()
    }

    private func snapshot(role: String = "AXMenuBarItem", selected: Bool = false) -> AppSnapshot {
        let app = RunningAppDescriptor(name: "Test", bundleIdentifier: "test.menu-focus", pid: -1,
                                       runningApplication: .current)
        let record = ElementRecord(
            index: 8, identifier: nil, element: AXUIElementCreateApplication(-1),
            localFrame: CGRect(x: 10, y: 10, width: 50, height: 20), role: role,
            rawActions: ["AXPress"], prettyActions: [], selectionState: .init(selected: NSNumber(value: selected))
        )
        return AppSnapshot(
            app: app, windowTitle: nil, windowBounds: CGRect(x: 0, y: 0, width: 400, height: 100),
            targetWindowID: 10, targetWindowLayer: nil, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: [8: record]
        )
    }

    private func click(_ service: ComputerUseService, method: ClickMethod = .auto) throws -> ToolCallResult {
        try ComputerUseToolDispatcher(service: service).callTool(name: "click", arguments: [
            "app": "test.menu-focus", "element_index": 8, "click_method": method.rawValue
        ])
    }

    func testCompleteEntryPreparesBeforeExactlyOneAXPress() throws {
        for method in [ClickMethod.auto, .accessibility] {
            var events: [String] = []
            let service = ComputerUseService(
                snapshots: ["test.menu-focus": snapshot()], snapshotDependencies: .live,
                axActionBackend: { _, _ in events.append("press"); return .success },
                descendantCandidatesBackend: { _ in XCTFail("不能继续候选点击"); return [] },
                menuBarFocusBackend: .init(foregroundPID: { 99 }, validate: { _, _ in events.append("validate") },
                                           prepare: { _, submit in
                                               events.append("prepare")
                                               try submit()
                                               events.append("finish")
                                           })
            )
            XCTAssertFalse(try click(service, method: method).isError)
            XCTAssertEqual(events, ["validate", "prepare", "validate", "press", "finish"])
        }
    }

    func testPreflightAndPreparationFailuresSendNothing() throws {
        for stage in ["initial", "prepare", "changed", "permission", "timeout", "cancelled"] {
            var reads = 0
            var sends = 0
            let service = ComputerUseService(
                snapshots: ["test.menu-focus": snapshot()], snapshotDependencies: .live,
                axActionBackend: { _, _ in sends += 1; return .success },
                descendantCandidatesBackend: { _ in XCTFail("失败不能换目标"); return [] },
                menuBarFocusBackend: .init(foregroundPID: { 99 }, validate: { _, _ in
                    reads += 1
                    if stage == "cancelled" { throw CancellationError() }
                    let failsInitially = ["initial", "permission", "timeout"].contains(stage)
                    if failsInitially || (stage == "changed" && reads == 2) {
                        throw ComputerUseError.stateUnavailable(stage)
                    }
                }, prepare: { _, submit in
                    if stage == "prepare" { throw ComputerUseError.stateUnavailable(stage) }
                    try submit()
                })
            )
            XCTAssertThrowsError(try click(service))
            XCTAssertEqual(sends, 0, stage)
        }
    }

    func testAttemptedAXFailureDoesNotReplayOrFallBack() throws {
        var sends = 0
        var cleanups = 0
        let service = ComputerUseService(
            snapshots: ["test.menu-focus": snapshot()], snapshotDependencies: .live,
            axActionBackend: { _, _ in sends += 1; return .cannotComplete },
            descendantCandidatesBackend: { _ in XCTFail("未知结果不能换候选"); return [] },
            menuBarFocusBackend: .init(foregroundPID: { 99 }, validate: { _, _ in }, prepare: { _, submit in
                defer { cleanups += 1 }
                try submit()
            })
        )
        // cannotComplete 保留未知结果错误，不能因 AX 已尝试而重新发送按键或鼠标。
        XCTAssertThrowsError(try click(service)) { error in
            XCTAssertTrue(String(describing: error).contains("effect is unknown"))
        }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(cleanups, 1)
    }

    func testOrdinaryControlsForegroundAndObservedMenusKeepOriginalRoute() throws {
        for (role, selected, foreground) in [
            ("AXButton", false, false), ("AXPopUpButton", false, false),
            ("AXMenuBarItem", true, false), ("AXMenuBarItem", false, true)
        ] {
            var sends = 0
            let service = ComputerUseService(
                snapshots: ["test.menu-focus": snapshot(role: role, selected: selected)], snapshotDependencies: .live,
                axActionBackend: { _, _ in sends += 1; return .success },
                menuBarFocusBackend: .init(foregroundPID: { foreground ? -1 : 99 }, validate: { _, _ in
                    XCTFail("原路径不能增加焦点校验")
                }, prepare: { _, _ in XCTFail("原路径不能增加焦点准备") })
            )
            XCTAssertFalse(try click(service).isError)
            XCTAssertEqual(sends, 1)
        }
    }

    func testUnavailablePreparationKeepsOriginalAXRouteBeforeAnyPreparation() throws {
        var sends = 0
        let service = ComputerUseService(
            snapshots: ["test.menu-focus": snapshot()], snapshotDependencies: .live,
            axActionBackend: { _, _ in sends += 1; return .success },
            menuBarFocusBackend: .init(foregroundPID: { 99 }, validate: { _, _ in
                XCTFail("能力缺失不能进入新路径")
            }, prepare: { _, _ in XCTFail("能力缺失不能准备焦点") }, isAvailable: { false })
        )
        XCTAssertFalse(try click(service).isError)
        XCTAssertEqual(sends, 1)
    }

    func testScopeExcludesMenuCommandsRightClickAndMultipleClick() throws {
        let state = snapshot()
        let record = try XCTUnwrap(state.elements[8])
        for (button, count) in [(MouseButtonKind.right, 1), (.left, 2), (.middle, 1)] {
            XCTAssertFalse(AXMenuBarFocus.applies(record: record, snapshot: state, button: button,
                                                  clickCount: count, foregroundPID: 99))
        }
        let commandState = snapshot(role: "AXMenuItem")
        XCTAssertFalse(try AXMenuBarFocus.applies(record: XCTUnwrap(commandState.elements[8]), snapshot: commandState,
                                                  button: .left, clickCount: 1, foregroundPID: 99))
    }
}
