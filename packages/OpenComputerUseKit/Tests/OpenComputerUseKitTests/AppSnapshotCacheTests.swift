import AppKit
@testable import OpenComputerUseKit
import XCTest

/// 合成 descriptor 仅承载 API 形状；测试不读取当前 App 的启动时间或终止标记。
func popupTestProcessIdentity(for pid: pid_t) -> SnapshotProcessIdentity? {
    SnapshotProcessIdentity(pid: pid, launchDate: Date(timeIntervalSince1970: 1000))
}

func popupTestBindingIdentity(for app: RunningAppDescriptor) -> SnapshotProcessIdentity? {
    popupTestProcessIdentity(for: app.pid)
}

final class AppSnapshotCacheTests: XCTestCase {
    func testInvalidationRetainsOnlyBindingAndReleasesInputRecords() throws {
        var stale: AppSnapshot? = snapshot(bundle: "test.first")
        weak let oldElement = stale?.elements[1]
        var cache = try AppSnapshotCache(
            snapshots: ["alias": XCTUnwrap(stale)], bindingIdentity: popupTestBindingIdentity
        )
        let original = try XCTUnwrap(cache.observationBinding(for: "alias"))
        XCTAssertNotNil(original.processIdentity)
        stale = nil
        XCTAssertNotNil(oldElement)
        cache.invalidate(query: "alias")
        XCTAssertNil(oldElement)
        for alias in ["alias", "shared", " TEST.FIRST "] {
            XCTAssertThrowsError(try cache.snapshot(for: alias))
            let retained = try XCTUnwrap(cache.observationBinding(for: alias))
            XCTAssertEqual(retained.app.pid, original.app.pid)
            XCTAssertEqual(retained.app.bundleIdentifier, original.app.bundleIdentifier)
            XCTAssertEqual(retained.processIdentity, original.processIdentity)
        }
        // 动作回读不能用保留的身份绕过失效状态。
        XCTAssertThrowsError(try cache.recordReadBack(snapshot(bundle: "test.first"), for: "alias"))
        XCTAssertThrowsError(try cache.snapshot(for: "alias"))
    }

    func testKnownNamesakeDoesNotReplaceInvalidatedAliasBinding() throws {
        var cache = AppSnapshotCache(
            snapshots: ["alias": snapshot(bundle: "test.first")], bindingIdentity: popupTestBindingIdentity
        )
        cache.recordObservation(snapshot(bundle: "test.second"), for: "test.second")
        cache.invalidate(query: "shared")
        XCTAssertEqual(cache.observationBinding(for: "shared")?.app.bundleIdentifier, "test.first")
        XCTAssertEqual(cache.observationBinding(for: "alias")?.app.bundleIdentifier, "test.first")
        XCTAssertThrowsError(try cache.snapshot(for: "test.first"))
        XCTAssertEqual(try cache.snapshot(for: "test.second").app.bundleIdentifier, "test.second")
        XCTAssertNil(cache.observationBinding(for: "unknown"))
    }

    func testBindingValidationRejectsMissingOrChangedProcessIdentity() throws {
        let app = snapshot(bundle: "test.first").app
        let binding = SnapshotObservationBinding(app: app, processIdentity: popupTestBindingIdentity(for: app))
        let original = try XCTUnwrap(binding.processIdentity)
        XCTAssertNoThrow(try binding.validate(current: original))
        let wrongPID = SnapshotProcessIdentity(pid: app.pid + 1, launchDate: original.launchDate)
        let mismatched = SnapshotObservationBinding(app: app, processIdentity: wrongPID)
        XCTAssertThrowsError(try mismatched.validate(current: wrongPID))
        for replacement: SnapshotProcessIdentity? in [
            nil,
            .init(pid: original.pid + 1, launchDate: original.launchDate),
            .init(pid: original.pid, launchDate: original.launchDate.addingTimeInterval(1))
        ] {
            XCTAssertThrowsError(try binding.validate(current: replacement))
        }
        let unknown = SnapshotObservationBinding(app: RunningAppDescriptor(
            name: "unknown", bundleIdentifier: nil, pid: original.pid + 1, runningApplication: .current
        ), processIdentity: nil)
        XCTAssertNil(unknown.processIdentity)
        XCTAssertThrowsError(try unknown.validate(current: nil))
    }

    func testGetAppStateExplicitlyRebindsAfterFailedPopupObservation() throws {
        let key = "OPEN_COMPUTER_USE_LIVE_PREVIEW"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "0", 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        let original = snapshot(bundle: "test.first")
        let replacement = snapshot(bundle: "test.second")
        var resolutions = 0
        var builds: [String?] = []
        let service = ComputerUseService(
            snapshots: ["shared": original],
            snapshotDependencies: .init(
                resolve: { _ in resolutions += 1; return replacement.app },
                build: { app, _, _, policy in
                    XCTAssertEqual(policy, .readOnly)
                    builds.append(app.bundleIdentifier)
                    if app.bundleIdentifier == original.app.bundleIdentifier {
                        throw ComputerUseError.message("initial failure")
                    }
                    return replacement
                },
                processIdentity: popupTestProcessIdentity,
                bindingIdentity: popupTestBindingIdentity,
                prepareOpen: { _ in
                    XCTFail("Explicit observation must not reopen")
                    throw ComputerUseError.message("unexpected open")
                },
                captureHoverPopups: { _, _ in .init(popups: []) }
            )
        )
        XCTAssertThrowsError(try service.hover(app: "shared", arguments: ["observe_only": true]))
        let rebound = try service.getAppState(app: "shared", initialize: false)
        XCTAssertEqual(rebound.content.first?.dictionary["text"] as? String, replacement.renderedText)
        let observed = try service.hover(app: "shared", arguments: ["observe_only": true])
        XCTAssertEqual(observed.content.first?.dictionary["text"] as? String, replacement.renderedText)
        XCTAssertEqual(observed.content.count, 2)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(builds, ["test.first", "test.second", "test.second"])
    }

    private func snapshot(bundle: String) -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(
                name: "shared", bundleIdentifier: bundle,
                pid: 11, runningApplication: .current
            ),
            windowTitle: "test", windowBounds: nil, targetWindowID: nil, targetWindowLayer: nil,
            screenshotData: nil, mode: .accessibility, treeLines: [], focusedSummary: nil,
            focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: [1: ElementRecord(index: 1, identifier: nil, element: nil, localFrame: nil,
                                        rawActions: [], prettyActions: [])]
        )
    }
}
