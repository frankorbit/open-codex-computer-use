import AppKit
@testable import OpenComputerUseKit
import XCTest

final class ApplicationInitializationRecoveryTests: XCTestCase {
    func testColdOpenFailureThroughNewAliasInvalidatesOnlyMatchingIdentity() throws {
        let harness = OpeningHarness()
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        _ = try service.getAppState(app: "old-alias")
        harness.resolveFailure = .appNotFound("new-alias")
        harness.openFailure = .message("Unknown callback result")
        XCTAssertThrowsError(try service.getAppState(app: "new-alias", initialize: true))
        for alias in ["old-alias", "Editor", "test.editor"] {
            XCTAssertThrowsError(try service.setValue(app: alias, elementIndex: "missing", value: "")) { error in
                XCTAssertEqual(error.localizedDescription, AppSnapshotCache.observationRequiredMessage)
            }
        }
    }

    func testColdUnknownOpenCannotBeReplayedThroughAnotherAlias() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        harness.openFailure = .message("Unknown callback result")
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        for processVisible in [false, true] {
            harness.resolveFailure = processVisible ? nil : .appNotFound("Editor")
            harness.failuresRemaining = 30
            for alias in ["test.editor", "/Applications/Editor.app", "Installed Editor"] {
                XCTAssertThrowsError(try service.getAppState(app: alias, initialize: true))
                XCTAssertEqual(harness.opens, 1)
            }
        }
        harness.failuresRemaining = 0
        _ = try service.getAppState(app: "test.editor")
        harness.openFailure = nil
        harness.failuresRemaining = 6
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 2)
    }

    func testSameNameRebindingDoesNotTransferOrClearPendingInitialization() throws {
        let first = OpeningHarness()
        let second = RunningAppDescriptor(name: "Editor", bundleIdentifier: "test.second", pid: 42000,
                                          runningApplication: .current)
        var targetSecond = false
        var secondOpens = 0
        var dependencies = first.dependencies
        dependencies.resolve = { _ in targetSecond ? second : first.app }
        dependencies.prepareOpen = { _ in
            if targetSecond {
                return ApplicationOpeningRequest(identity: .bundle("test.second"), perform: {
                    secondOpens += 1
                    return second
                })
            }
            return try first.dependencies.prepareOpen("Editor")
        }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        first.failuresRemaining = 12
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        targetSecond = true
        first.failuresRemaining = 6
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(secondOpens, 1)
        targetSecond = false
        first.failuresRemaining = 6
        XCTAssertThrowsError(try service.getAppState(app: "test.editor", initialize: true))
        XCTAssertEqual(first.opens, 1)
    }

    func testFailedFirstBindingCanRecoverWithoutAnotherOpen() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        harness.failuresRemaining = 6
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        // 尚无窗口时再次 getApp，不重复发送打开请求。
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        XCTAssertEqual(harness.opens, 1)
        harness.resolveFailure = nil
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 1)
    }

    func testPendingInitializationFollowsResolvedAliasesAndClearsAfterObservation() throws {
        let harness = OpeningHarness()
        harness.failuresRemaining = 40
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "initial-alias", initialize: true))
        for alias in ["test.editor", "Editor", "another-resolved-alias"] {
            XCTAssertThrowsError(try service.getAppState(app: alias, initialize: true))
            XCTAssertEqual(harness.opens, 1)
        }
        harness.failuresRemaining = 0
        _ = try service.getAppState(app: "another-resolved-alias")
        // 成功观察结束本次初始化；后续关闭窗口是新的生命周期。
        harness.failuresRemaining = 6
        _ = try service.getAppState(app: "initial-alias", initialize: true)
        XCTAssertEqual(harness.opens, 2)
    }

    func testUncertainOpenFailureDoesNotReplayAcrossCalls() {
        let harness = OpeningHarness()
        harness.failuresRemaining = 40
        harness.openFailure = .message("System callback failed")
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true)) { error in
            XCTAssertEqual(error.localizedDescription, "System callback failed")
        }
        XCTAssertThrowsError(try service.getAppState(app: "test.editor", initialize: true))
        XCTAssertEqual(harness.opens, 1)
    }

    func testMissingInstallationCanBeInitializedAfterInstallation() throws {
        let harness = OpeningHarness()
        harness.resolveFailure = .appNotFound("Editor")
        harness.prepareFailure = .appNotFound("Editor")
        let service = ComputerUseService(snapshotDependencies: harness.dependencies)
        XCTAssertThrowsError(try service.getAppState(app: "Editor", initialize: true))
        harness.prepareFailure = nil
        _ = try service.getAppState(app: "Editor", initialize: true)
        XCTAssertEqual(harness.opens, 1)
    }

    func testInitializingAnotherApplicationPreservesExistingSnapshot() throws {
        for failure: ComputerUseError? in [nil, .appNotFound("Other"), .message("unknown open result")] {
            let editor = OpeningHarness()
            let other = OpeningHarness()
            other.openFailure = failure
            var dependencies = editor.dependencies
            let editorResolve = dependencies.resolve
            dependencies.resolve = { query in
                if query == "Other" { throw ComputerUseError.appNotFound(query) }
                return try editorResolve(query)
            }
            dependencies.prepareOpen = { _ in
                if case .appNotFound = other.openFailure { throw ComputerUseError.appNotFound("Other") }
                return ApplicationOpeningRequest(identity: .bundle("test.other"), perform: {
                    other.opens += 1
                    if let failure = other.openFailure { throw failure }
                    return RunningAppDescriptor(name: "Other", bundleIdentifier: "test.other", pid: 42000,
                                                runningApplication: .current)
                })
            }
            let service = ComputerUseService(snapshotDependencies: dependencies)
            _ = try service.getAppState(app: "Editor")
            if failure == nil {
                _ = try service.getAppState(app: "Other", initialize: true)
            } else {
                XCTAssertThrowsError(try service.getAppState(app: "Other", initialize: true))
            }
            assertSnapshotAvailable(service, query: "Editor")
            assertSnapshotAvailable(service, query: "test.editor")
        }
    }

    func testOtherAppReadbackFailurePreservesExistingSnapshot() throws {
        let harness = OpeningHarness()
        var dependencies = harness.dependencies
        let resolve = dependencies.resolve
        dependencies.resolve = { query in
            if query == "Other" { throw ComputerUseError.appNotFound(query) }
            return try resolve(query)
        }
        dependencies.prepareOpen = { _ in
            ApplicationOpeningRequest(identity: .bundle("test.other"), perform: {
                RunningAppDescriptor(name: "Other", bundleIdentifier: "test.other", pid: 42000,
                                     runningApplication: .current)
            })
        }
        let service = ComputerUseService(snapshotDependencies: dependencies)
        _ = try service.getAppState(app: "Editor")
        harness.failuresRemaining = 6
        XCTAssertThrowsError(try service.getAppState(app: "Other", initialize: true))
        assertSnapshotAvailable(service, query: "Editor")
    }

    private func assertSnapshotAvailable(_ service: ComputerUseService, query: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        // 不存在的元素只检查缓存，不向真实应用投递输入。
        XCTAssertThrowsError(try service.setValue(app: query, elementIndex: "missing", value: ""),
                             file: file, line: line) { error in
            guard case ComputerUseError.invalidArguments("unknown element_index 'missing'") = error else {
                return XCTFail("Expected preserved snapshot, got \(error)", file: file, line: line)
            }
        }
    }
}
