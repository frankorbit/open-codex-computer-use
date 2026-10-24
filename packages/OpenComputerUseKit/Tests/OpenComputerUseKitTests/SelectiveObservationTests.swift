import AppKit
import XCTest
@testable import OpenComputerUseKit

final class SelectiveObservationTests: XCTestCase {
    private func app(pid: Int32 = 42, name: String = "ObservationFixture") -> RunningAppDescriptor {
        .init(name: name, bundleIdentifier: "test.\(name)", pid: pid, runningApplication: .current)
    }

    private func snapshot(pid: Int32 = 42, name: String = "ObservationFixture",
                          options: SnapshotObservationOptions = .defaults) -> AppSnapshot {
        let state = FixtureAppState(windowTitle: "test", windowBounds: .init(rect: CGRect(x: 0, y: 0, width: 300, height: 200)),
                                    focusedIdentifier: "input", elements: [
            .init(identifier: "input", index: 7, role: "text", title: "Input", value: "中文🙂", actions: [],
                  frame: .init(rect: CGRect(x: 10, y: 10, width: 100, height: 30)))
        ])
        return SnapshotBuilder.buildFixtureSnapshot(app: app(pid: pid, name: name), state: state, observation: options)
    }

    /// 通过 fork 的快照缓存观察；构建闭包按请求的采集选项生成 fixture 快照。
    private func observedService() -> ComputerUseService {
        ComputerUseService(snapshotDependencies: SnapshotDependencies(
            resolve: { _ in self.app(pid: getpid()) },
            build: { _, _, _, policy, observation in
                XCTAssertEqual(policy, .readOnly)
                return self.snapshot(pid: getpid(), options: observation)
            },
            processIdentity: popupTestProcessIdentity,
            bindingIdentity: popupTestBindingIdentity,
            prepareOpen: { _ in XCTFail("must not open"); throw ComputerUseError.message("unexpected") },
            captureHoverPopups: { _, _ in HoverPopupCaptureResult() }
        ))
    }

    func testEmptyObservationFailsBeforeResolvingApp() {
        XCTAssertThrowsError(try ComputerUseService().getAppState(app: "missing-test-app",
            observation: .init(includeAX: false, includeScreenshot: false))) {
            XCTAssertTrue(String(describing: $0).contains("At least one"))
        }
    }

    func testDispatcherRequiresActualJSONBooleans() {
        let dispatcher = ComputerUseToolDispatcher()
        for key in ["include_ax", "include_screenshot"] {
            for value: Any in ["false", 0, 1, NSNull(), [], [:]] {
                XCTAssertThrowsError(try dispatcher.callTool(name: "get_app_state", arguments: ["app": "missing-test-app", key: value])) {
                    XCTAssertTrue(String(describing: $0).contains("\(key) must be a boolean"))
                }
            }
        }
    }

    func testSchemaHasMatchingFullDefaults() throws {
        let tool = try XCTUnwrap(ToolDefinitions.all.first { $0.name == "get_app_state" })
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        for key in ["include_ax", "include_screenshot"] {
            let value = try XCTUnwrap(properties[key] as? [String: Any])
            XCTAssertEqual(value["type"] as? String, "boolean")
            XCTAssertEqual(value["default"] as? Bool, true)
        }
    }

    func testCLIObservationOptionsAndDefaultCompatibility() throws {
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit"]), .snapshot(app: "TextEdit"))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["snapshot", "--include-screenshot", "false", "TextEdit"]),
                       .snapshot(app: "TextEdit", observation: .init(includeScreenshot: false)))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit", "--include-ax", "FALSE"]),
                       .snapshot(app: "TextEdit", observation: .init(includeAX: false)))
        for args in [["--include-ax"], ["--include-screenshot", "0"], ["--include-ax", "no"],
                     ["--include-ax", "false", "--include-screenshot", "false"]] {
            XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit"] + args))
        }
    }

    func testFixtureChannelsPreserveOrOmitAXAndCoordinateGuidance() {
        let full = snapshot()
        XCTAssertEqual(full.elements.count, 1)
        let image = snapshot(options: .init(includeAX: false))
        XCTAssertTrue(image.elements.isEmpty)
        XCTAssertTrue(image.treeLines.isEmpty)
        XCTAssertNil(image.focusedSummary)
        XCTAssertNil(image.selectedText)
        XCTAssertTrue(image.renderedText.contains("indexes invalidated"))
        let ax = snapshot(options: .init(includeScreenshot: false))
        XCTAssertEqual(ax.elements.count, 1)
        XCTAssertNil(ax.screenshotData)
        XCTAssertEqual(ax.screenshotNote, SnapshotObservationOptions.screenshotOmittedNote)
    }

    func testScreenshotOnlyObservationDropsElementIndexesUntilAXIsReadAgain() throws {
        let service = observedService()
        XCTAssertTrue(try service.getAppState(app: "ObservationFixture").primaryText?.contains("7 text") == true)
        let image = try service.getAppState(app: "ObservationFixture", observation: .init(includeAX: false))
        XCTAssertTrue(image.primaryText?.contains("indexes invalidated") == true)
        // 不含 AX 的观察替换缓存快照：旧编号在任何输入之前就无法解析。
        XCTAssertThrowsError(try service.performSecondaryAction(app: "ObservationFixture", elementIndex: "7", action: "AXPress"))
        let ax = try service.getAppState(app: "ObservationFixture", observation: .init(includeScreenshot: false))
        XCTAssertTrue(ax.primaryText?.contains("7 text") == true)
    }

    func testQueryIndexInvalidationIsScopedAndNeverReissuesIDs() throws {
        let registry = TargetedElementRegistry<String>()
        let first = TargetedAppIdentity(pid: 42, bundleIdentifier: "a", launchedAt: nil)
        let other = TargetedAppIdentity(pid: 99, bundleIdentifier: "b", launchedAt: nil)
        let a = registry.insert(app: first) { _ in "a" }
        let b = registry.insert(app: other) { _ in "b" }
        registry.removeAll(forPIDs: [42])
        XCTAssertThrowsError(try registry.resolve(a, app: first))
        XCTAssertEqual(try registry.resolve(b, app: other), "b")
        XCTAssertGreaterThan(registry.insert(app: first) { _ in "new" }, b)
    }

    func testAXOnlyRejectsCoordinateInputBeforeAnyInput() {
        let backend = CoordinateClickBackend(
            validateWindow: { _, _ in XCTFail("must not validate a window") },
            hitTest: { _, _ in XCTFail("must not hit-test"); return nil },
            performMouse: { _, _, _, _ in XCTFail("must not send input") }
        )
        let service = ComputerUseService(snapshots: ["fixture": snapshot(pid: getpid(), options: .init(includeScreenshot: false))],
                                         coordinateClickBackend: backend)
        XCTAssertThrowsError(try service.click(app: "fixture", elementIndex: nil, x: 10, y: 10,
                                              clickCount: 1, mouseButton: "left")) {
            XCTAssertTrue(String(describing: $0).contains("include_screenshot=false"))
        }
        XCTAssertThrowsError(try service.drag(app: "fixture", fromX: 1, fromY: 1, toX: 2, toY: 2)) {
            XCTAssertTrue(String(describing: $0).contains("include_screenshot=false"))
        }
    }
}
