import AppKit
@testable import OpenComputerUseKit
import XCTest

final class ApplicationOpeningTests: XCTestCase {
    func testPreparingOpenFixesIdentityWithoutDispatchingLaunch() throws {
        var launches = 0
        let expected = RunningAppDescriptor(name: "Editor", bundleIdentifier: nil, pid: 41002,
                                            runningApplication: .current)
        let request = try AppDiscovery.prepareOpen(
            "Editor", running: [],
            locate: { _ in URL(fileURLWithPath: "/Applications/Editor.app") },
            launch: { _ in
                launches += 1
                return expected
            }
        )
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(request.identity, .path("/Applications/Editor.app"))
        XCTAssertEqual(try request.perform().pid, expected.pid)
        XCTAssertEqual(launches, 1)
    }

    func testObservationResolutionDoesNotStartAbsentApplication() {
        XCTAssertThrowsError(try AppDiscovery.resolve("Not Running", in: [])) { error in
            guard case ComputerUseError.appNotFound("Not Running") = error else {
                return XCTFail("Expected missing process, got \(error)")
            }
        }
    }

    func testOpenKeepsCallbackIdentityWhenBundleNameAndProcessNameDiffer() throws {
        let expected = RunningAppDescriptor(name: "Running Name", bundleIdentifier: "test.actual", pid: 41002,
                                             runningApplication: .current)
        let url = URL(fileURLWithPath: "/Applications/Installed Name.app")
        var launches: [URL] = []
        let app = try AppDiscovery.open("Installed Name", running: [], locate: { query in
            XCTAssertEqual(query, "Installed Name")
            return url
        }, launch: { target in
            launches.append(target)
            return expected
        })
        XCTAssertEqual(launches, [url])
        XCTAssertEqual(app.pid, expected.pid)
        XCTAssertEqual(app.bundleIdentifier, expected.bundleIdentifier)
        XCTAssertEqual(app.name, "Running Name")
    }

    func testObservationResolvesInstalledAliasToRunningBundleWithoutLaunching() throws {
        let running = RunningAppDescriptor(name: "Runtime Name", bundleIdentifier: "test.actual", pid: 41002,
                                            runningApplication: .current)
        let resolved = try AppDiscovery.resolve("Installed Name", in: [running], installedBundleIdentifier: { query in
            XCTAssertEqual(query, "Installed Name")
            return "test.actual"
        })
        XCTAssertEqual(resolved.pid, running.pid)
        XCTAssertEqual(resolved.bundleIdentifier, running.bundleIdentifier)
        XCTAssertThrowsError(try AppDiscovery.resolve("Installed Name", in: [], installedBundleIdentifier: { _ in
            "test.actual"
        }))
    }

    func testLaunchFailureIsNotRetriedOrLookedUpAgain() {
        var launches = 0
        var lookups = 0
        XCTAssertThrowsError(try AppDiscovery.open("Installed Name", running: [], locate: { _ in
            lookups += 1
            return URL(fileURLWithPath: "/Applications/Installed Name.app")
        }, launch: { _ in
            launches += 1
            throw ComputerUseError.permissionDenied("denied")
        }))
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(launches, 1)
    }

    func testOrdinaryObservationNeverOpensEvenWhenWindowIsMissing() {
        let harness = OpeningHarness()
        harness.failuresRemaining = 10
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor"))
        XCTAssertEqual(harness.opens, 0)
        XCTAssertEqual(harness.builds, 6)
        XCTAssertTrue(harness.policies.allSatisfy { $0 == .readOnly })
    }

    func testBindingExistingWindowDoesNotOpen() throws {
        let harness = OpeningHarness()
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 0)
        XCTAssertEqual(harness.builds, 1)
        assertCache(service, app: "test.editor", available: true)
    }

    func testColdBindingUsesReturnedProcessAndOnlyRetriesObservation() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        harness.failuresRemaining = 2
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        let result = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.resolves, 1)
        XCTAssertEqual(harness.builds, 3)
        XCTAssertEqual(harness.builtPIDs, [41002, 41002, 41002])
        XCTAssertTrue(harness.policies.allSatisfy { $0 == .readOnly })
        assertCache(service, app: "test.editor", available: true)
    }

    func testColdBindingByInstalledAliasSupportsSubsequentObservation() throws {
        let harness = OpeningHarness()
        var dependencies = harness.dependencies
        dependencies.resolve = { query in
            try AppDiscovery.resolve(
                query, in: harness.opens == 0 ? [] : [harness.openedApp],
                installedBundleIdentifier: { _ in "test.editor" }
            )
        }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        _ = try service.getAppState(app: "Installed Name", initialize: true)
        _ = try service.getAppState(app: "Installed Name")
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builtPIDs, [41002, 41002])
    }

    func testRunningWithoutWindowReopensOnceAndObservesCallbackIdentity() throws {
        let harness = OpeningHarness()
        harness.failuresRemaining = 8
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builds, 9)
        XCTAssertEqual(Array(harness.builtPIDs.suffix(3)), [41002, 41002, 41002])
        XCTAssertTrue(harness.policies.allSatisfy { $0 == .readOnly })
    }

    func testTransientMissingWindowDoesNotReopen() throws {
        let harness = OpeningHarness()
        harness.failuresRemaining = 2
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 0)
        XCTAssertEqual(harness.builds, 3)
    }

    func testFailedOpenInvalidatesExistingAliasesAndPreservesPermissionReason() throws {
        let harness = OpeningHarness()
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "old-alias")
        harness.failuresRemaining = 10
        harness.openFailure = .permissionDenied("Apple Events permission denied")
        XCTAssertThrowsError(try service.getAppState(app: "new-alias", initialize: true)) { error in
            XCTAssertEqual(error.localizedDescription, "Apple Events permission denied")
        }
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builds, 7)
        for alias in ["old-alias", "test.editor", "Editor"] {
            assertCache(service, app: alias, available: false)
        }
    }

    func testReadBackFailureNeverReplaysOpenAndDoesNotPublishSnapshot() {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        harness.failuresRemaining = 10
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cgWindowNotFound"))
        }
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builds, 6)
        assertCache(service, app: "test.editor", available: false)
        // 随后的普通观察不能把失败的初始化隐式重放。
        XCTAssertThrowsError(try service.getAppState(app: "Editor"))
        XCTAssertEqual(harness.opens, 1)
    }

    func testPermissionFailureDuringObservationNeverOpensOrRetries() {
        let harness = OpeningHarness()
        harness.buildFailure = .permissionDenied("Accessibility permission is required")
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        XCTAssertEqual(harness.opens, 0)
        XCTAssertEqual(harness.builds, 1)
    }

    func testOtherObservationFailureDoesNotTriggerReopen() {
        let harness = OpeningHarness()
        harness.buildFailure = .stateUnavailable("capture transport failed")
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        XCTAssertEqual(harness.opens, 0)
        XCTAssertEqual(harness.builds, 1)
    }

    func testDispatchValidatesLifecycleFlagBeforeOpeningAndKeepsToolCount() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        let dispatcher = ComputerUseToolDispatcher(service: service)
        for value: Any in ["true", 1, NSNull()] {
            let result = dispatcher.callToolAsResult(
                name: "get_app_state", arguments: ["app": "Editor", "initialize": value]
            )
            XCTAssertTrue(result.isError)
        }
        XCTAssertEqual(harness.opens, 0)
        let observation = dispatcher.callToolAsResult(
            name: "get_app_state", arguments: ["app": "Editor", "initialize": false]
        )
        XCTAssertTrue(observation.isError)
        XCTAssertEqual(harness.opens, 0)
        let result = try dispatcher.callTool(name: "get_app_state", arguments: ["app": "Editor"])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(harness.opens, 1)
        XCTAssertEqual(harness.builds, 1)
        XCTAssertFalse(ToolDefinitions.all.contains { $0.name == "open_app" })
        XCTAssertEqual(ToolDefinitions.all.count, 10)
    }

    func testInitializationAndPlacementAreRejectedBeforeSideEffects() {
        let harness = OpeningHarness()
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", windowPlacement: .agentDisplay, initialize: true))
        XCTAssertEqual(harness.opens, 0)
        XCTAssertEqual(harness.resolves, 0)
    }

    func testExplicitPlacementDoesNotImplicitlyInitialize() {
        let harness = OpeningHarness()
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        let dispatcher = ComputerUseToolDispatcher(service: service)
        // 合成快照没有 windowElement，故应到达既有放置错误，而非被 initialize 冲突提前挡住。
        let result = dispatcher.callToolAsResult(
            name: "get_app_state", arguments: ["app": "Editor", "window_placement": "agent_display"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(harness.builds, 1)
        XCTAssertEqual(harness.opens, 0)
        XCTAssertTrue(result.primaryText?.contains("requires a current target window") == true)
    }

    private func assertCache(_ service: ComputerUseService, app: String, available: Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        // 不存在的索引只检查缓存准入，不向真实应用发送输入。
        XCTAssertThrowsError(
            try service.setValue(app: app, elementIndex: "missing", value: ""), file: file, line: line
        ) { error in
            let message: String?
            if case let ComputerUseError.invalidArguments(reason) = error {
                message = reason
            } else {
                message = (error as? ComputerUseError)?.errorDescription
            }
            let expected = available ? "unknown element_index 'missing'" : AppSnapshotCache.observationRequiredMessage
            XCTAssertEqual(message, expected, file: file, line: line)
        }
    }
}

final class OpeningHarness {
    let app = RunningAppDescriptor(name: "Editor", bundleIdentifier: "test.editor", pid: 41001,
                                   runningApplication: .current)
    let openedApp = RunningAppDescriptor(name: "Editor", bundleIdentifier: "test.editor", pid: 41002,
                                         runningApplication: .current)
    var opens = 0
    var resolves = 0
    var builds = 0
    var failuresRemaining = 0
    var resolveFailure: ComputerUseError?
    var openFailure: ComputerUseError?
    var prepareFailure: ComputerUseError?
    var buildFailure: ComputerUseError?
    var policies: [SnapshotRecoveryPolicy] = []
    var builtPIDs: [pid_t] = []

    var dependencies: SnapshotDependencies {
        SnapshotDependencies(
            resolve: { _ in
                self.resolves += 1
                if let failure = self.resolveFailure { throw failure }
                return self.app
            },
            build: { app, _, _, policy in
                self.builds += 1
                self.builtPIDs.append(app.pid)
                self.policies.append(policy)
                if let failure = self.buildFailure { throw failure }
                if self.failuresRemaining > 0 {
                    self.failuresRemaining -= 1
                    throw ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage)
                }
                return AppSnapshot(
                    app: app, windowTitle: "Editor", windowBounds: nil, targetWindowID: 123, targetWindowLayer: 0,
                    screenshotData: nil, mode: .accessibility, treeLines: [], focusedSummary: nil,
                    focusedElement: nil, selectedText: nil, windowElement: nil, elements: [:]
                )
            },
            prepareOpen: { _ in
                if let failure = self.prepareFailure { throw failure }
                return ApplicationOpeningRequest(identity: .bundle("test.editor"), perform: {
                    self.opens += 1
                    if let failure = self.openFailure { throw failure }
                    return self.openedApp
                })
            }
        )
    }
}
