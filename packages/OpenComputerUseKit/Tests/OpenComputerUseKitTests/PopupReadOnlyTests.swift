import AppKit
@testable import OpenComputerUseKit
import XCTest

final class PopupReadOnlyTests: XCTestCase {
    private let environmentKeys = [
        "OPEN_COMPUTER_USE_EXECUTION_MODE", "OPEN_COMPUTER_USE_FOREGROUND_HOVER",
        "OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_LIVE_PREVIEW"
    ]
    private var savedEnvironment: [String: String] = [:]

    override func setUp() {
        super.setUp()
        for key in environmentKeys {
            savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "0", 1)
        }
        unsetenv("OPEN_COMPUTER_USE_EXECUTION_MODE")
    }

    override func tearDown() {
        for key in environmentKeys {
            if let value = savedEnvironment[key] {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        super.tearDown()
    }

    func testReadOnlyRequestCannotCarryPointerInput() throws {
        let request = try HoverRequest(arguments: ["observe_only": true])
        guard case .observation = request.target else { return XCTFail("Expected read-only observation") }
        XCTAssertEqual(request.durationMilliseconds, 0)
        for arguments: [String: Any] in [
            ["observe_only": false], ["observe_only": 1], ["observe_only": "true"],
            ["observe_only": true, "x": 1], ["observe_only": true, "y": 1],
            ["observe_only": true, "element_index": "1"], ["observe_only": true, "duration_ms": 0]
        ] {
            XCTAssertThrowsError(try HoverRequest(arguments: arguments))
        }
    }

    func testServiceObservesExistingPopupWithoutAXWindowOrInputAndInvalidatesTokens() throws {
        let key = "OPEN_COMPUTER_USE_FOREGROUND_HOVER"
        let old = ProcessInfo.processInfo.environment[key]
        setenv(key, "1", 1)
        defer { if let old { setenv(key, old, 1) } else { unsetenv(key) } }
        let (snapshot, popup) = fixture()
        let app = snapshot.app
        let token = popup.token
        var readbacks = 0
        let service = ComputerUseService(
            snapshots: ["test.popup": snapshot],
            snapshotDependencies: SnapshotDependencies(
                resolve: { _ in app },
                build: { _, _, _, policy, _ in
                    XCTAssertEqual(policy, .readOnly)
                    readbacks += 1
                    return snapshot
                },
                processIdentity: popupTestProcessIdentity,
                bindingIdentity: popupTestBindingIdentity,
                captureHoverPopups: { _, mode in
                    XCTAssertEqual(mode, .explicit)
                    return .init(popups: [popup])
                }
            )
        )
        let dispatcher = ComputerUseToolDispatcher(service: service)
        let server = StdioMCPServer(service: service, backgroundStateReset: {})
        for invalidate in [
            { dispatcher.discardHoverPopups() },
            { server.endSession() }
        ] {
            let before = readbacks
            let result = try dispatcher.callTool(name: "hover", arguments: ["app": "test.popup", "observe_only": true])
            XCTAssertFalse(result.isError)
            XCTAssertEqual(readbacks, before + 1)
            XCTAssertEqual(result.content.count, 3)
            let image = try XCTUnwrap(result.content.last?.dictionary)
            let metadata = try XCTUnwrap((image["_meta"] as? [String: Any])?["ocuPopup"] as? [String: Any])
            XCTAssertEqual(metadata["token"] as? String, token)
            invalidate()
            XCTAssertThrowsError(try service.clickPopup(
                app: "test.popup",
                arguments: ["popup_token": token, "x": 1, "y": 1]
            )) {
                XCTAssertTrue($0.localizedDescription.contains("No current popup_token"))
            }
        }
    }

    func testOrdinaryObservationIncludesPopupAndInvalidArgumentsConsumeLease() throws {
        let key = "OPEN_COMPUTER_USE_EXECUTION_MODE"
        let old = ProcessInfo.processInfo.environment[key]
        setenv(key, "background", 1)
        defer { if let old { setenv(key, old, 1) } else { unsetenv(key) } }
        let (snapshot, legacyPopup) = fixture()
        var captures = 0
        let service = ComputerUseService(
            snapshots: ["test.popup": snapshot],
            snapshotDependencies: SnapshotDependencies(
                resolve: { _ in snapshot.app },
                build: { _, _, _, policy, _ in
                    XCTAssertEqual(policy, .readOnly)
                    return snapshot
                },
                processIdentity: popupTestProcessIdentity,
                bindingIdentity: popupTestBindingIdentity,
                captureHoverPopups: { _, mode in
                    XCTAssertEqual(mode, .ordinary)
                    captures += 1
                    var popup = legacyPopup
                    popup.permitsBackgroundInput = true
                    return .init(popups: [popup])
                }
            )
        )
        let dispatcher = ComputerUseToolDispatcher(service: service)
        let result = try dispatcher.callTool(name: "get_app_state", arguments: [
            "app": "test.popup", "initialize": false
        ])
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(result.content.count, 3)
        let metadata = (result.content.last?.dictionary["_meta"] as? [String: Any])?["ocuPopup"] as? [String: Any]
        XCTAssertEqual(metadata?["clickMethod"] as? String, "sky_click")
        XCTAssertEqual(metadata?["backgroundClickCapable"] as? Bool, true)
        XCTAssertThrowsError(try dispatcher.callTool(name: "click", arguments: [
            "app": "test.popup", "popup_token": legacyPopup.token,
            "x": 1, "y": 1, "click_method": "sky_click", "modifiers": []
        ]))
        XCTAssertThrowsError(try service.clickPopup(app: "test.popup", arguments: [
            "popup_token": legacyPopup.token, "x": 1, "y": 1, "click_method": "sky_click"
        ])) {
            XCTAssertTrue($0.localizedDescription.contains("No current popup_token"))
        }
        XCTAssertEqual(captures, 1)
    }

    func testIncompleteObservationKeepsMainSnapshotButDropsAllPopupTokens() throws {
        let (snapshot, popup) = fixture()
        var captures = 0
        let service = ComputerUseService(
            snapshots: ["test.popup": snapshot],
            snapshotDependencies: .init(
                resolve: { _ in snapshot.app }, build: { _, _, _, _, _ in snapshot },
                processIdentity: popupTestProcessIdentity,
                bindingIdentity: popupTestBindingIdentity,
                captureHoverPopups: { _, _ in
                    captures += 1
                    // 即便依赖错误地携带部分旧图片，incomplete 也不能把它们变成新凭证。
                    return .init(popups: [popup], isIncomplete: captures == 2)
                }
            )
        )
        _ = try service.hover(app: "test.popup", arguments: ["observe_only": true])
        let result = try service.hover(app: "test.popup", arguments: ["observe_only": true])
        let text = result.content.compactMap { $0.dictionary["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Popup observation incomplete"))
        XCTAssertFalse(text.contains("No verifiable popup candidates"))
        XCTAssertFalse(text.contains("popup_token="))
        XCTAssertEqual(result.content.count, 2)
        XCTAssertThrowsError(try service.clickPopup(app: "test.popup", arguments: [
            "popup_token": popup.token, "x": 1, "y": 1
        ])) {
            XCTAssertTrue($0.localizedDescription.contains("No current popup_token"))
        }
        // 只读 hover 仍能使用主快照回读；附加观察失败不能破坏主状态缓存。
        XCTAssertNoThrow(try service.hover(app: "test.popup", arguments: ["observe_only": true]))
        XCTAssertEqual(captures, 3)
    }
}

extension PopupReadOnlyTests {
    func testExistingObservationPreservesBoundIdentityAndReplacesIndices() throws {
        let (old, _) = fixture(elementIndex: 1)
        let (fresh, _) = fixture(elementIndex: 2)
        var builds = 0
        var resolutions = 0
        let service = ComputerUseService(
            snapshots: ["shared name": old],
            snapshotDependencies: .init(
                resolve: { _ in
                    resolutions += 1
                    return RunningAppDescriptor(
                        name: old.app.name, bundleIdentifier: "test.namesake", pid: old.app.pid + 1,
                        runningApplication: .current
                    )
                },
                build: { app, _, _, policy, _ in
                    XCTAssertEqual(app.pid, old.app.pid)
                    XCTAssertEqual(app.bundleIdentifier, old.app.bundleIdentifier)
                    XCTAssertEqual(policy, .readOnly)
                    builds += 1
                    if builds == 2 { throw ComputerUseError.message("observation failed") }
                    return fresh
                },
                processIdentity: popupTestProcessIdentity,
                bindingIdentity: popupTestBindingIdentity,
                prepareOpen: unexpectedOpen,
                captureHoverPopups: { _, mode in
                    XCTAssertEqual(mode, .explicit)
                    return .init(popups: [])
                }
            )
        )
        for attempt in 1 ... 3 {
            if attempt == 2 {
                XCTAssertThrowsError(try service.hover(app: "shared name", arguments: ["observe_only": true]))
                assertSnapshotUnavailable(service, query: "shared name")
                continue
            }
            let result = try service.hover(app: "shared name", arguments: ["observe_only": true])
            XCTAssertEqual(result.content.count, 2)
            XCTAssertTrue(result.content.first?.dictionary["text"] as? String == fresh.renderedText)
            assertFreshIndices(service, query: "shared name")
        }
        XCTAssertEqual(builds, 3)
        XCTAssertEqual(resolutions, 0)
    }

    func testFailedObservationRecoversReadOnlyWithFreshIndicesAndToken() throws {
        setenv("OPEN_COMPUTER_USE_EXECUTION_MODE", "background", 1)
        let (old, oldPopup) = fixture(elementIndex: 1)
        let (fresh, freshPopup) = fixture(elementIndex: 2)
        var builds = 0
        var resolutions = 0
        var captures = 0
        let service = ComputerUseService(
            snapshots: ["test.popup": old],
            snapshotDependencies: .init(
                resolve: { _ in resolutions += 1; return old.app },
                build: { app, _, _, policy, _ in
                    XCTAssertEqual(app.pid, old.app.pid)
                    XCTAssertEqual(policy, .readOnly)
                    builds += 1
                    if builds == 2 { throw ComputerUseError.message("observation failed") }
                    if builds == 3 { throw ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage) }
                    return builds == 1 ? old : fresh
                },
                processIdentity: popupTestProcessIdentity,
                bindingIdentity: popupTestBindingIdentity,
                prepareOpen: unexpectedOpen,
                captureHoverPopups: { _, mode in
                    XCTAssertEqual(mode, .explicit)
                    captures += 1
                    var popup = captures == 1 ? oldPopup : freshPopup
                    popup.permitsBackgroundInput = true
                    return .init(popups: [popup])
                }
            ),
            allowsForegroundClickOnce: true
        )
        let dispatcher = ComputerUseToolDispatcher(service: service)
        let arguments: [String: Any] = ["app": "test.popup", "observe_only": true]
        XCTAssertEqual(try popupToken(dispatcher.callTool(name: "hover", arguments: arguments)), oldPopup.token)
        assertLeaseCanBeIssued(oldPopup, snapshot: old)
        XCTAssertThrowsError(try dispatcher.callTool(name: "hover", arguments: arguments)) {
            XCTAssertTrue($0.localizedDescription.contains("observation failed"))
        }
        assertSnapshotUnavailable(service, query: "fixture")
        let recovered = try dispatcher.callTool(name: "hover", arguments: arguments)
        XCTAssertEqual(recovered.content.count, 3)
        XCTAssertEqual(recovered.content.first?.dictionary["text"] as? String, fresh.renderedText)
        XCTAssertNil(service.takeForegroundObservation())
        XCTAssertEqual(popupToken(recovered), freshPopup.token)
        XCTAssertEqual(builds, 4)
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(captures, 2)
        assertPopupTokenRejected(service, token: oldPopup.token)
        assertFreshIndices(service, query: "fixture")
    }

    func testReadOnlyObservationNeverGrantsOrPreservesForegroundEligibility() throws {
        setenv("OPEN_COMPUTER_USE_EXECUTION_MODE", "background", 1)
        for useDispatcher in [false, true] {
            for hasPriorObservation in [false, true] {
                let (snapshot, _) = fixture()
                let service = ComputerUseService(
                    snapshotDependencies: .init(
                        resolve: { _ in snapshot.app },
                        build: { _, _, _, policy, _ in
                            XCTAssertEqual(policy, .readOnly)
                            return snapshot
                        },
                        processIdentity: popupTestProcessIdentity,
                        bindingIdentity: popupTestBindingIdentity,
                        prepareOpen: unexpectedOpen,
                        captureHoverPopups: { _, _ in .init(popups: []) }
                    ),
                    allowsForegroundClickOnce: true
                )
                let dispatcher = ComputerUseToolDispatcher(service: service)
                if hasPriorObservation {
                    _ = try service.getAppState(app: "test.popup")
                    XCTAssertNotNil(service.takeForegroundObservation())
                    _ = try service.getAppState(app: "test.popup")
                }
                if useDispatcher {
                    _ = try dispatcher.callTool(name: "hover", arguments: ["app": "test.popup", "observe_only": true])
                } else {
                    _ = try service.hover(app: "test.popup", arguments: ["observe_only": true])
                }
                let observation = service.takeForegroundObservation()
                XCTAssertNil(observation)
                XCTAssertThrowsError(try service.clickForegroundOnce(
                    app: "test.popup", x: 1, y: 1, observation: observation
                )) {
                    XCTAssertTrue($0.localizedDescription.contains("Run get_app_state immediately before"))
                }
            }
        }
    }

    private func unexpectedOpen(_: String) throws -> ApplicationOpeningRequest {
        XCTFail("Read-only observation must not launch or reopen")
        throw ComputerUseError.message("unexpected open")
    }

    private func assertPopupTokenRejected(
        _ service: ComputerUseService, token: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try service.clickPopup(app: "test.popup", arguments: [
            "popup_token": token, "x": 1, "y": 1, "click_method": "sky_click"
        ]), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains("No current popup_token"), file: file, line: line)
        }
    }

    private func assertLeaseCanBeIssued(_ popup: HoverPopupObservation, snapshot: AppSnapshot) {
        // 确认旧凭证原本可入缓存，防止“从未发放 token”的假阳性。
        var issued = HoverPopupCache()
        var clickable = popup
        clickable.permitsBackgroundInput = true
        issued.record([clickable], snapshot: snapshot, now: ProcessInfo.processInfo.systemUptime)
        XCTAssertNoThrow(try issued.take(popup.token))
    }

    private func popupToken(_ result: ToolCallResult) -> String? {
        let metadata = result.content.last?.dictionary["_meta"] as? [String: Any]
        return (metadata?["ocuPopup"] as? [String: Any])?["token"] as? String
    }

    private func assertSnapshotUnavailable(
        _ service: ComputerUseService, query: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try service.setValue(app: query, elementIndex: "1", value: "unused"), file: file, line: line
        ) {
            XCTAssertTrue(
                $0.localizedDescription.contains(AppSnapshotCache.observationRequiredMessage), file: file, line: line
            )
        }
    }

    private func assertFreshIndices(
        _ service: ComputerUseService, query: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        // 使用无 AX 对象的记录验证索引替换，绝不发送输入。
        for (index, expected) in [("1", "unknown element_index"), ("2", "has no backing accessibility object")] {
            XCTAssertThrowsError(
                try service.setValue(app: query, elementIndex: index, value: "unused"), file: file, line: line
            ) {
                XCTAssertTrue($0.localizedDescription.contains(expected), file: file, line: line)
            }
        }
    }

    private func fixture(elementIndex: Int? = nil) -> (AppSnapshot, HoverPopupObservation) {
        let app = RunningAppDescriptor(
            name: "fixture", bundleIdentifier: "test.popup",
            pid: 11, runningApplication: .current
        )
        // 无 AXWindow 的合成快照使任何激活、鼠标准备都会失败；只读分支仍应成功。
        let snapshot = AppSnapshot(
            app: app, windowTitle: "fixture",
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            targetWindowID: 1, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
            treeLines: elementIndex.map { ["\($0): text fixture"] } ?? [],
            focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: elementIndex.map { index in
                [index: ElementRecord(index: index, identifier: nil, element: nil,
                                      localFrame: nil, rawActions: [], prettyActions: [])]
            } ?? [:]
        )
        let popup = HoverPopupObservation(
            token: UUID().uuidString, windowID: 2, pid: app.pid,
            bounds: CGRect(x: 100, y: 100, width: 100, height: 100),
            captureBounds: CGRect(x: 100, y: 100, width: 100, height: 100),
            imageData: Data([1]), pixelSize: CGSize(width: 200, height: 200)
        )
        return (snapshot, popup)
    }
}
