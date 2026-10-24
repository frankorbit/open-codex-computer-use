import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class SnapshotInvalidationTests: XCTestCase {
    private var previousReadBack: String?

    override func setUp() {
        super.setUp()
        previousReadBack = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_ACTION_READ_BACK"]
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0", 1)
    }

    override func tearDown() {
        if let previousReadBack {
            setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", previousReadBack, 1)
        } else {
            unsetenv("OPEN_COMPUTER_USE_ACTION_READ_BACK")
        }
        super.tearDown()
    }

    func testSingleForegroundObservationIsConsumedBeforeArgumentValidation() throws {
        let harness = SnapshotHarness()
        harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001)
        let service = ComputerUseService(snapshotDependencies: harness.dependencies, allowsForegroundClickOnce: true)
        let dispatcher = ComputerUseToolDispatcher(service: service)
        _ = try dispatcher.callTool(name: "get_app_state", arguments: ["app": "Editor", "initialize": false])
        XCTAssertThrowsError(try dispatcher.callTool(name: "click_foreground_once", arguments: [
            "app": "Editor", "x": 10, "y": 10, "purpose": "open_control", "click_count": 2,
        ]))
        XCTAssertNil(service.takeForegroundObservation())
        _ = try dispatcher.callTool(name: "get_app_state", arguments: ["app": "Editor", "initialize": false])
        // 普通输入即使参数错误也会消费资格，不会替它自动升级。
        XCTAssertThrowsError(try dispatcher.callTool(name: "click", arguments: [:]))
        XCTAssertNil(service.takeForegroundObservation())
    }

    func testListAppsStillConsumesSingleForegroundObservationEvenOnInvalidArguments() throws {
        let harness = SnapshotHarness()
        harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001)
        let service = ComputerUseService(snapshotDependencies: harness.dependencies, allowsForegroundClickOnce: true)
        let dispatcher = ComputerUseToolDispatcher(service: service)
        for invalid in [false, true] {
            _ = try dispatcher.callTool(name: "get_app_state", arguments: ["app": "Editor", "initialize": false])
            if invalid {
                XCTAssertThrowsError(try dispatcher.callTool(name: "list_apps", arguments: ["unexpected": true]))
            } else {
                XCTAssertFalse(try dispatcher.callTool(name: "list_apps", arguments: [:]).isError)
            }
            XCTAssertNil(service.takeForegroundObservation())
        }
    }

    func testSingleForegroundMissingScreenshotInvalidatesInputSnapshotAndCannotReplay() throws {
        let harness = SnapshotHarness()
        harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001)
        let service = ComputerUseService(snapshotDependencies: harness.dependencies, allowsForegroundClickOnce: true)
        let dispatcher = ComputerUseToolDispatcher(service: service)
        _ = try dispatcher.callTool(name: "get_app_state", arguments: ["app": "Editor", "initialize": false])
        let args: [String: Any] = ["app": "Editor", "x": 10, "y": 10, "purpose": "open_control"]
        XCTAssertThrowsError(try dispatcher.callTool(name: "click_foreground_once", arguments: args)) { error in
            XCTAssertTrue(error.localizedDescription.contains("screenshot"))
        }
        XCTAssertThrowsError(try dispatcher.callTool(name: "click_foreground_once", arguments: args)) { error in
            XCTAssertTrue(error.localizedDescription.contains("immediately before"))
        }
        assertInputDenied(service, query: "Editor")
    }

    func testInputCacheMissNeverResolvesOrBuilds() {
        let harness = SnapshotHarness()
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        assertAllInputEntrypointsDenied(service, query: "test.editor")
        XCTAssertTrue(harness.resolvedQueries.isEmpty)
        XCTAssertTrue(harness.builtPIDs.isEmpty)
    }

    func testFailedObservationBlocksAllAliasesAndActualInputEntrypoints() throws {
        let harness = SnapshotHarness()
        let app = harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001, aliases: ["short", "editor.app"])
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "short")
        _ = try service.getAppState(app: "editor.app")
        harness.buildFailures[app.pid] = .stateUnavailable(computerUseNoWindowFoundMessage)

        let buildsBeforeFailure = harness.builtPIDs.count
        XCTAssertThrowsError(try service.getAppState(app: "Editor"))
        XCTAssertEqual(harness.builtPIDs.count - buildsBeforeFailure, 6)
        let resolvesAfterFailure = harness.resolvedQueries.count
        let buildsAfterFailure = harness.builtPIDs.count
        for alias in ["short", "editor.app", "Editor", " TEST.EDITOR "] {
            assertAllInputEntrypointsDenied(service, query: alias)
        }
        XCTAssertEqual(harness.resolvedQueries.count, resolvesAfterFailure)
        XCTAssertEqual(harness.builtPIDs.count, buildsAfterFailure)
    }

    func testResolveFailureInvalidatesKnownTargetButPreservesOtherApp() throws {
        let harness = SnapshotHarness()
        harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001, aliases: ["short"])
        harness.addApp(name: "Browser", bundle: "test.browser", pid: 41002)
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "short")
        _ = try service.getAppState(app: "Browser")
        harness.resolveFailures.insert("short")

        XCTAssertThrowsError(try service.getAppState(app: " SHORT "))
        XCTAssertThrowsError(try service.getAppState(app: "short"))
        for alias in ["short", "Editor", "test.editor"] {
            assertInputDenied(service, query: alias)
        }
        assertSnapshotAvailable(service, query: "Browser")
        assertSnapshotAvailable(service, query: "test.browser")
    }

    func testUnknownResolveFailureDoesNotInvalidateUnrelatedApps() throws {
        let harness = SnapshotHarness()
        harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001)
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "Editor")

        XCTAssertThrowsError(try service.getAppState(app: "unknown"))
        assertInputDenied(service, query: "unknown")
        assertSnapshotAvailable(service, query: "Editor")
        assertSnapshotAvailable(service, query: "test.editor")
    }

    func testFailureThroughNewAliasInvalidatesExistingTarget() throws {
        let harness = SnapshotHarness()
        let app = harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001, aliases: ["new-alias"])
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "Editor")
        harness.buildFailures[app.pid] = .message("snapshot transport failed")

        XCTAssertThrowsError(try service.getAppState(app: "new-alias"))
        harness.resolveFailures.insert("new-alias")
        XCTAssertThrowsError(try service.getAppState(app: "new-alias"))
        for alias in ["new-alias", "Editor", "test.editor"] {
            assertInputDenied(service, query: alias)
        }
    }

    func testSameNameAndReboundAliasDoNotInvalidateOtherTarget() throws {
        let harness = SnapshotHarness()
        harness.addApp(name: "Shared", bundle: "test.first", pid: 41001, aliases: ["short"])
        let second = harness.addApp(name: "Shared", bundle: "test.second", pid: 41002)
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "short")
        _ = try service.getAppState(app: "test.second")
        harness.apps["short"] = second
        harness.buildFailures[second.pid] = .message("snapshot failed")

        XCTAssertThrowsError(try service.getAppState(app: "short"))
        assertInputDenied(service, query: "short")
        assertInputDenied(service, query: "test.second")
        assertSnapshotAvailable(service, query: "test.first")
        assertSnapshotAvailable(service, query: "Shared")
    }

    func testOnlySuccessfulExplicitObservationRestoresAllKnownAliases() throws {
        let harness = SnapshotHarness()
        let original = harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001, aliases: ["short"])
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "short")
        harness.buildFailures[original.pid] = .message("snapshot failed")
        XCTAssertThrowsError(try service.getAppState(app: "Editor"))

        harness.buildFailures.removeAll()
        assertInputDenied(service, query: "short")
        let replacement = harness.addApp(name: "Editor", bundle: "test.editor", pid: 41003, mode: .fixture)
        _ = try service.getAppState(app: "test.editor")
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "1", 1)
        let resolvesBeforeAction = harness.resolvedQueries.count
        for alias in ["short", "Editor", "test.editor"] {
            _ = try service.performSecondaryAction(app: alias, elementIndex: "1", action: "Raise")
            XCTAssertEqual(harness.builtPIDs.last, replacement.pid)
        }
        XCTAssertEqual(harness.resolvedQueries.count, resolvesBeforeAction)
        XCTAssertTrue(harness.policies.allSatisfy { $0 == .readOnly })
    }

    func testActionReadBackFailureBlocksFurtherInputUntilExplicitObservation() throws {
        let harness = SnapshotHarness()
        let app = harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001, mode: .fixture)
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "Editor")
        harness.buildFailures[app.pid] = .message("read-back failed")
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "1", 1)

        XCTAssertThrowsError(try service.performSecondaryAction(app: "Editor", elementIndex: "1", action: "Raise"))
        XCTAssertEqual(harness.policies, [.readOnly, .readOnly])
        harness.buildFailures.removeAll()
        let buildCount = harness.builtPIDs.count
        assertInputDenied(service, query: "test.editor")
        XCTAssertEqual(harness.builtPIDs.count, buildCount)

        _ = try service.getAppState(app: "test.editor")
        _ = try service.performSecondaryAction(app: "Editor", elementIndex: "1", action: "Raise")
        XCTAssertEqual(harness.resolvedQueries.count, 2)
        XCTAssertTrue(harness.policies.allSatisfy { $0 == .readOnly })
    }

    func testParkAndRestoreFailuresInvalidateIntermediateSnapshotAndAliases() throws {
        for placement in [WindowPlacement.agentDisplay, .restore] {
            let harness = SnapshotHarness()
            harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001, aliases: ["short"])
            harness.addApp(name: "Browser", bundle: "test.browser", pid: 41002)
            harness.placementFails = true
            let service = ComputerUseService(snapshotDependencies: harness.dependencies)
            _ = try service.getAppState(app: "short")
            _ = try service.getAppState(app: "Browser")
            let buildsBeforePlacement = harness.builtPIDs.count
            harness.duringPlacement = { [weak service] in
                guard let service else { return XCTFail("service unavailable") }
                self.assertInputDenied(service, query: "short")
                self.assertSnapshotAvailable(service, query: "Browser")
            }

            XCTAssertThrowsError(try service.getAppState(app: "Editor", windowPlacement: placement)) { error in
                XCTAssertEqual((error as? ComputerUseError)?.errorDescription, "placement failed")
            }
            XCTAssertEqual(harness.placements, [placement])
            XCTAssertEqual(harness.builtPIDs.count, buildsBeforePlacement + 1)
            for alias in ["short", "Editor", "test.editor"] {
                assertInputDenied(service, query: alias)
            }
            assertSnapshotAvailable(service, query: "Browser")
        }
    }

    func testFinalObservationFailureAfterPlacementInvalidatesIntermediateSnapshot() throws {
        for placement in [WindowPlacement.agentDisplay, .restore] {
            let harness = SnapshotHarness()
            harness.addApp(name: "Editor", bundle: "test.editor", pid: 41001, aliases: ["short"])
            harness.failBuildAfterPlacement = true
            let service = ComputerUseService(snapshotDependencies: harness.dependencies)
            _ = try service.getAppState(app: "short")

            XCTAssertThrowsError(try service.getAppState(app: "Editor", windowPlacement: placement))
            XCTAssertEqual(harness.placements, [placement])
            XCTAssertEqual(harness.builtPIDs.count, 3)
            for alias in ["short", "Editor", "test.editor"] {
                assertInputDenied(service, query: alias)
            }
        }
    }
}

private extension SnapshotInvalidationTests {
    private func assertInputDenied(
        _ service: ComputerUseService,
        query: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertObservationRequired(file: file, line: line) {
            try service.setValue(app: query, elementIndex: "missing", value: "must not be written")
        }
    }

    private func assertAllInputEntrypointsDenied(
        _ service: ComputerUseService,
        query: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actions: [() throws -> ToolCallResult] = [
            {
                try service
                    .click(app: query, elementIndex: "missing", x: nil, y: nil, clickCount: 1, mouseButton: "left") },
            { try service.setValue(app: query, elementIndex: "missing", value: "must not be written") },
            { try service.performSecondaryAction(app: query, elementIndex: "missing", action: "Raise") },
            { try service.scroll(app: query, direction: "down", elementIndex: "missing", pages: 1) },
            { try service.drag(app: query, fromX: 0, fromY: 0, toX: 1, toY: 1) },
            { try service.typeText(app: query, text: "must not be written") },
            // 非法按键也必须先被缓存门禁拒绝；即使回归，也不创建真实键盘事件。
            { try service.pressKey(app: query, key: "invalid-snapshot-test-key") }
        ]
        for action in actions {
            assertObservationRequired(file: file, line: line, action)
        }
    }

    private func assertObservationRequired(file: StaticString, line: UInt, _ action: () throws -> ToolCallResult) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            guard case let ComputerUseError.stateUnavailable(message) = error else {
                return XCTFail("Expected observation gate, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(message, AppSnapshotCache.observationRequiredMessage, file: file, line: line)
        }
    }

    private func assertSnapshotAvailable(
        _ service: ComputerUseService,
        query: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 用不存在的索引确认已越过缓存门禁，不向真实 App 发送输入。
        XCTAssertThrowsError(
            try service.setValue(app: query, elementIndex: "missing", value: ""),
            file: file,
            line: line
        ) { error in
            guard case let ComputerUseError.invalidArguments(message) = error else {
                return XCTFail("Expected element lookup, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(message, "unknown element_index 'missing'", file: file, line: line)
        }
    }
}

private final class SnapshotHarness {
    var apps: [String: RunningAppDescriptor] = [:]
    var snapshots: [pid_t: AppSnapshot] = [:]
    var resolveFailures: Set<String> = []
    var buildFailures: [pid_t: ComputerUseError] = [:]
    var resolvedQueries: [String] = []
    var builtPIDs: [pid_t] = []
    var policies: [SnapshotRecoveryPolicy] = []
    var placements: [WindowPlacement] = []
    var placementFails = false
    var failBuildAfterPlacement = false
    var duringPlacement: (() -> Void)?

    var dependencies: SnapshotDependencies {
        SnapshotDependencies(
            resolve: { query in
                let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                self.resolvedQueries.append(key)
                guard !self.resolveFailures.contains(key), let app = self.apps[key] else {
                    throw ComputerUseError.appNotFound(query)
                }
                return app
            },
            build: { app, _, _, policy, _ in
                self.builtPIDs.append(app.pid)
                self.policies.append(policy)
                if let failure = self.buildFailures[app.pid] { throw failure }
                return try XCTUnwrap(self.snapshots[app.pid])
            },
            parkWindow: { _, pid, _ in try self.place(.agentDisplay, pid: pid) },
            restoreWindows: { pid in try self.place(.restore, pid: pid) }
        )
    }

    @discardableResult
    func addApp(name: String, bundle: String, pid: pid_t, aliases: [String] = [],
                mode: SnapshotMode = .accessibility) -> RunningAppDescriptor {
        let app = RunningAppDescriptor(name: name, bundleIdentifier: bundle, pid: pid, runningApplication: .current)
        for alias in aliases + [name, bundle] {
            apps[alias.lowercased()] = app
        }
        let record = ElementRecord(
            index: 1,
            identifier: nil,
            element: nil,
            localFrame: nil,
            rawActions: [],
            prettyActions: []
        )
        snapshots[pid] = AppSnapshot(
            app: app, windowTitle: name, windowBounds: nil, targetWindowID: 123, targetWindowLayer: 0,
            screenshotData: nil, mode: mode, treeLines: [], focusedSummary: nil, focusedElement: nil,
            selectedText: nil, windowElement: AXUIElementCreateApplication(pid), elements: [1: record]
        )
        return app
    }

    private func place(_ placement: WindowPlacement, pid: pid_t) throws {
        placements.append(placement)
        duringPlacement?()
        if placementFails { throw ComputerUseError.message("placement failed") }
        if failBuildAfterPlacement { buildFailures[pid] = .message("final observation failed") }
    }
}
