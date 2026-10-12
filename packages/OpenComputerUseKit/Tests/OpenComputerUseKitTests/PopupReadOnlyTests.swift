import AppKit
@testable import OpenComputerUseKit
import XCTest

final class PopupReadOnlyTests: XCTestCase {
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
                build: { _, _, _, policy in
                    XCTAssertEqual(policy, .readOnly)
                    readbacks += 1
                    return snapshot
                },
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
            try invalidate()
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
                build: { _, _, _, policy in
                    XCTAssertEqual(policy, .readOnly)
                    return snapshot
                },
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
                resolve: { _ in snapshot.app }, build: { _, _, _, _ in snapshot },
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

    private func fixture() -> (AppSnapshot, HoverPopupObservation) {
        let app = RunningAppDescriptor(
            name: "fixture",
            bundleIdentifier: "test.popup",
            pid: 11,
            runningApplication: .current
        )
        // 无 AXWindow 的合成快照使任何激活、鼠标准备都会失败；只读分支仍应成功。
        let snapshot = AppSnapshot(
            app: app,
            windowTitle: "fixture",
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            targetWindowID: 1,
            targetWindowLayer: 0,
            screenshotData: nil,
            mode: .accessibility,
            treeLines: [],
            focusedSummary: nil,
            focusedElement: nil,
            selectedText: nil,
            windowElement: nil,
            elements: [:]
        )
        let token = UUID().uuidString
        let popup = HoverPopupObservation(
            token: token,
            windowID: 2,
            pid: 11,
            bounds: CGRect(x: 100, y: 100, width: 100, height: 100),
            imageData: Data([1]),
            pixelSize: CGSize(width: 200, height: 200)
        )
        return (snapshot, popup)
    }
}
