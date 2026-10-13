import AppKit
@testable import OpenComputerUseKit
import XCTest

final class StrictPopupReadOnlyTests: XCTestCase {
    private let keys = [
        "OPEN_COMPUTER_USE_EXECUTION_MODE", "OPEN_COMPUTER_USE_FOREGROUND_HOVER",
        "OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_LIVE_PREVIEW"
    ]
    private var saved: [String: String] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "0", 1)
        }
        setenv(keys[0], "background", 1)
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        super.tearDown()
    }

    private func service(
        processIdentity: ((pid_t) -> SnapshotProcessIdentity?)? = nil,
        readBack: @escaping () throws -> Void,
        capture: @escaping () -> Void
    ) -> ComputerUseService {
        let snapshot = AppSnapshot(
            app: RunningAppDescriptor(
                name: "popup",
                bundleIdentifier: "test.popup",
                pid: 11,
                runningApplication: .current
            ),
            windowTitle: "test", windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            targetWindowID: 1, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil,
            windowElement: nil, elements: [:]
        )
        // 无 AXWindow、无元素；误入激活或指针路径无法成功返回弹层内容。
        return ComputerUseService(snapshots: ["test.popup": snapshot], snapshotDependencies: SnapshotDependencies(
            resolve: { _ in
                XCTFail("must not resolve another target, including after invalidation")
                throw ComputerUseError.message("unexpected")
            },
            build: { app, _, _, policy in
                XCTAssertEqual(app.pid, snapshot.app.pid)
                XCTAssertEqual(app.bundleIdentifier, snapshot.app.bundleIdentifier)
                XCTAssertEqual(policy, .readOnly)
                try readBack()
                return snapshot
            },
            processIdentity: processIdentity ?? popupTestProcessIdentity,
            bindingIdentity: popupTestBindingIdentity,
            prepareOpen: { _ in XCTFail("must not open"); throw ComputerUseError.message("unexpected") },
            captureHoverPopups: { _, mode in
                XCTAssertEqual(mode, .explicit)
                capture()
                return .init(popups: [HoverPopupObservation(
                    token: "read-only-popup", windowID: 2, pid: snapshot.app.pid,
                    bounds: CGRect(x: 100, y: 100, width: 100, height: 100),
                    captureBounds: CGRect(x: 100, y: 100, width: 100, height: 100),
                    imageData: Data([1]), pixelSize: CGSize(width: 100, height: 100)
                )])
            }
        ))
    }

    func testServiceAndHiddenDispatcherToolObserveWithForegroundFlagOff() throws {
        for strict in [true, false] {
            if strict { setenv(keys[0], "background", 1) } else { unsetenv(keys[0]) }
            XCTAssertFalse(ToolDefinitions.available().contains { $0.name == "hover" })
            var builds = 0
            var captures = 0
            let service = service(readBack: { builds += 1 }, capture: { captures += 1 })
            let direct = try service.hover(app: "test.popup", arguments: ["observe_only": true])
            let manual = try ComputerUseToolDispatcher(service: service).callTool(
                name: "hover", arguments: ["app": "test.popup", "observe_only": true]
            )
            for result in [direct, manual] {
                XCTAssertFalse(result.isError)
                XCTAssertEqual(result.content.count, 3)
                let metadata = (result.content.last?
                    .dictionary["_meta"] as? [String: Any])?["ocuPopup"] as? [String: Any]
                if strict {
                    XCTAssertNil(metadata?["token"])
                    XCTAssertEqual(metadata?["observationOnly"] as? Bool, true)
                } else {
                    XCTAssertEqual(metadata?["token"] as? String, "read-only-popup")
                }
            }
            XCTAssertEqual(builds, 2)
            XCTAssertEqual(captures, 2)
        }
    }

    func testActualHoverIsRejectedBeforeMissingSnapshotDespiteLegacyFlag() {
        setenv("OPEN_COMPUTER_USE_FOREGROUND_HOVER", "1", 1)
        let service = ComputerUseService()
        let dispatcher = ComputerUseToolDispatcher(service: service)
        for arguments: [String: Any] in [["x": 1, "y": 1], ["element_index": "1"]] {
            XCTAssertThrowsError(try service.hover(app: "missing", arguments: arguments)) {
                XCTAssertTrue($0.localizedDescription.contains("background execution mode"))
            }
            var manualArguments = arguments
            manualArguments["app"] = "missing"
            XCTAssertThrowsError(try dispatcher.callTool(name: "hover", arguments: manualArguments)) {
                XCTAssertTrue($0.localizedDescription.contains("background execution mode"))
            }
        }
    }

    func testUnknownModeRejectsReadOnlyAtServiceAndDispatcherBeforeReadBack() {
        setenv(keys[0], "typo", 1)
        let service = service(readBack: { XCTFail("unexpected readback") }, capture: { XCTFail("unexpected capture") })
        XCTAssertThrowsError(try service.hover(app: "test.popup", arguments: ["observe_only": true])) {
            XCTAssertTrue($0.localizedDescription.contains("Unknown OPEN_COMPUTER_USE_EXECUTION_MODE"))
        }
        XCTAssertThrowsError(try ComputerUseToolDispatcher(service: service).callTool(
            name: "hover", arguments: ["app": "test.popup", "observe_only": true]
        )) {
            XCTAssertTrue($0.localizedDescription.contains("Unknown OPEN_COMPUTER_USE_EXECUTION_MODE"))
        }
    }

    func testReadOnlyFailureInvalidatesSnapshotAndNextExplicitObservationRebuilds() {
        var builds = 0
        let service = service(
            readBack: { builds += 1; throw ComputerUseError.message("read failed") },
            capture: { XCTFail("unexpected capture") }
        )
        let dispatcher = ComputerUseToolDispatcher(service: service)
        for attempt in 1 ... 2 {
            XCTAssertThrowsError(try dispatcher.callTool(
                name: "hover", arguments: ["app": "test.popup", "observe_only": true]
            )) {
                XCTAssertTrue($0.localizedDescription.contains("read failed"))
            }
            // 非无窗口错误不在同一调用内重试；下一次显式观察仅重建原进程快照。
            XCTAssertEqual(builds, attempt)
            XCTAssertThrowsError(try service.setValue(app: "test.popup", elementIndex: "1", value: "unused")) {
                XCTAssertTrue($0.localizedDescription.contains(AppSnapshotCache.observationRequiredMessage))
            }
        }
    }

    func testRecoveryFailureLeavesAllAliasesInvalidAndDoesNotOpen() {
        for processMissing in [false, true] {
            var builds = 0
            let service = service(
                processIdentity: { pid in processMissing ? nil : popupTestProcessIdentity(for: pid) },
                readBack: { builds += 1; throw ComputerUseError.message("observation failed") },
                capture: { XCTFail("A failed main snapshot cannot issue popup evidence") }
            )
            for _ in 0 ..< 2 {
                XCTAssertThrowsError(try service.hover(app: "test.popup", arguments: ["observe_only": true]))
                for alias in ["test.popup", "popup"] {
                    XCTAssertThrowsError(try service.setValue(app: alias, elementIndex: "1", value: "unused")) {
                        XCTAssertTrue($0.localizedDescription.contains(AppSnapshotCache.observationRequiredMessage))
                    }
                }
                XCTAssertNil(service.takeForegroundObservation())
            }
            XCTAssertEqual(builds, processMissing ? 1 : 2)
        }
    }

    func testRecoveryRejectsExitedOrReusedProcessBeforeBuild() throws {
        let original = try XCTUnwrap(
            popupTestProcessIdentity(for: 11)
        )
        let replacements: [SnapshotProcessIdentity?] = [
            nil,
            .init(pid: original.pid, launchDate: original.launchDate.addingTimeInterval(1)),
            .init(pid: original.pid + 1, launchDate: original.launchDate)
        ]
        for replacement in replacements {
            var builds = 0
            let service = service(
                processIdentity: { pid in
                    XCTAssertEqual(pid, original.pid)
                    return replacement
                },
                readBack: { builds += 1; throw ComputerUseError.message("initial failure") },
                capture: { XCTFail("Failed recovery must not capture or issue a token") }
            )
            XCTAssertThrowsError(try service.hover(app: "test.popup", arguments: ["observe_only": true]))
            for alias in ["popup", " TEST.POPUP "] {
                XCTAssertThrowsError(try service.hover(app: alias, arguments: ["observe_only": true])) {
                    XCTAssertTrue($0.localizedDescription.contains("explicitly rebind"))
                }
                XCTAssertThrowsError(try service.setValue(app: alias, elementIndex: "1", value: "unused")) {
                    XCTAssertTrue($0.localizedDescription.contains(AppSnapshotCache.observationRequiredMessage))
                }
            }
            XCTAssertEqual(builds, 1)
            XCTAssertNil(service.takeForegroundObservation())
        }
    }

    func testProcessExitDuringRecoveryDoesNotPublishIntermediateSnapshot() throws {
        var current = try XCTUnwrap(
            popupTestProcessIdentity(for: 11)
        )
        var builds = 0
        var validations = 0
        let service = service(
            processIdentity: { _ in validations += 1; return current },
            readBack: {
                builds += 1
                if builds == 1 { throw ComputerUseError.message("initial failure") }
                current = .init(pid: current.pid, launchDate: current.launchDate.addingTimeInterval(1))
            },
            capture: { XCTFail("A changed process cannot publish the intermediate snapshot") }
        )
        XCTAssertThrowsError(try service.hover(app: "test.popup", arguments: ["observe_only": true]))
        XCTAssertThrowsError(try service.hover(app: "test.popup", arguments: ["observe_only": true])) {
            XCTAssertTrue($0.localizedDescription.contains("explicitly rebind"))
        }
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(validations, 2)
        XCTAssertThrowsError(try service.setValue(app: "popup", elementIndex: "1", value: "unused")) {
            XCTAssertTrue($0.localizedDescription.contains(AppSnapshotCache.observationRequiredMessage))
        }
    }
}
