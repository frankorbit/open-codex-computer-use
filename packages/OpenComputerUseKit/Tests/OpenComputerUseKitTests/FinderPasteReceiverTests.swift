import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class FinderPasteReceiverTests: XCTestCase {
    private var oldReadBack: String?

    override func setUp() {
        super.setUp()
        oldReadBack = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_ACTION_READ_BACK"]
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0", 1)
    }

    override func tearDown() {
        if let oldReadBack {
            setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", oldReadBack, 1)
        } else {
            unsetenv("OPEN_COMPUTER_USE_ACTION_READ_BACK")
        }
        super.tearDown()
    }

    private func dispatcher(
        read: @escaping (AppSnapshot, Bool) throws -> AXUIElement,
        window: @escaping (AppSnapshot) throws -> Void = { _ in },
        paste: @escaping (SkyKeyboardTarget, String, SkyPasteRoute, () throws -> Void) throws -> Void
    ) -> ComputerUseToolDispatcher {
        let snapshot = AppSnapshot(
            app: RunningAppDescriptor(
                name: "Finder", bundleIdentifier: "com.apple.finder", pid: getpid(), runningApplication: .current
            ),
            windowTitle: "Fixture", windowBounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            targetWindowID: 42, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: AXUIElementCreateApplication(999),
            selectedText: "stale selection", windowElement: nil, elements: [:]
        )
        let backend = KeyboardInputBackend(
            readReceiver: read,
            typeText: { _, _, _ in XCTFail("must not fall back to typing") },
            pressKey: { _, _, _ in XCTFail("must not fall back to another key") },
            validateWindow: window, pasteText: paste
        )
        return ComputerUseToolDispatcher(service: ComputerUseService(
            snapshots: ["finder": snapshot], keyboardInputBackend: backend
        ))
    }

    private func call(_ dispatcher: ComputerUseToolDispatcher) throws {
        _ = try dispatcher.callTool(name: "paste_text", arguments: ["app": "finder", "text": "归档测试"])
    }

    func testStableFinderEditorUsesOneKeySubmissionWithoutLookingUpFilePasteMenu() throws {
        let receiver = AXUIElementCreateApplication(123)
        var reads = 0
        var sends = 0
        let board = PasteTestClipboard()
        let dispatcher = dispatcher(read: { _, editable in
            XCTAssertTrue(editable)
            reads += 1
            return receiver
        }, paste: { target, text, route, validate in
            XCTAssertEqual(target.windowID, 42)
            XCTAssertEqual(route, .focusedText)
            try ClipboardInput.transact(text, store: board, validateReceiver: validate) { check, willSubmit in
                try dispatchSkyMenuKey(useMenuEquivalent: route == .menuEquivalent, findMenuItem: { () -> Int? in
                    XCTFail("Finder text must not invoke its file-list Paste command")
                    return 1
                }, validateReceiver: check, pressMenuItem: { _ in
                    XCTFail("must not press file Paste")
                }, postKey: { willSubmit(); sends += 1 })
            }
        })
        try call(dispatcher)
        XCTAssertGreaterThan(reads, 3)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(board.text, "归档测试")
    }

    func testFileListOrMissingEditorRejectsBeforeClipboardOrDeliveryEvenWithSelectedText() {
        let failures: [ComputerUseError] = [
            .stateUnavailable("outline ListView"), .stateUnavailable("missing editor"),
            .permissionDenied("permission denied"), .stateUnavailable("AX timeout")
        ]
        for failure in failures {
            var attempts = 0
            let dispatcher = dispatcher(read: { _, _ in throw failure }, paste: { _, _, _, _ in
                attempts += 1
            })
            XCTAssertThrowsError(try call(dispatcher)) {
                XCTAssertEqual($0.localizedDescription, failure.localizedDescription)
                if case .permissionDenied = failure {
                    guard case ComputerUseError.permissionDenied = $0 else {
                        return XCTFail("permission errors must preserve their category")
                    }
                }
            }
            XCTAssertEqual(attempts, 0)
        }
    }

    func testChangedEditorDuringKeyWindowPreparationSendsNothing() {
        var reads = 0
        var attempts = 0
        var sends = 0
        let board = PasteTestClipboard()
        let dispatcher = dispatcher(read: { _, _ in
            reads += 1
            return AXUIElementCreateApplication(reads == 1 ? 123 : 456)
        }, paste: { _, text, _, validate in
            attempts += 1
            try ClipboardInput.transact(text, store: board, validateReceiver: validate) { _, willSubmit in
                willSubmit(); sends += 1
            }
        })
        XCTAssertThrowsError(try call(dispatcher))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(board.writes, 0)
        XCTAssertEqual(board.text, "original")
    }

    func testFocusLostAfterStagingRestoresClipboardWithoutSendingOrReplaying() {
        let board = PasteTestClipboard()
        var attempts = 0
        var sends = 0
        let dispatcher = dispatcher(read: { _, _ in
            if board.writes > 0 { throw ComputerUseError.stateUnavailable("editor lost") }
            return AXUIElementCreateApplication(123)
        }, paste: { _, text, _, validate in
            attempts += 1
            try ClipboardInput.transact(text, store: board, validateReceiver: validate) { _, willSubmit in
                willSubmit(); sends += 1
            }
        })
        XCTAssertThrowsError(try call(dispatcher))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(board.text, "original")
        XCTAssertEqual(board.writes, 2)
    }

    func testUnknownSubmissionRetainsTextAndDoesNotFallBackOrReplay() {
        let board = PasteTestClipboard()
        var attempts = 0
        var sends = 0
        let dispatcher = dispatcher(read: { _, _ in
            AXUIElementCreateApplication(123)
        }, paste: { _, text, _, validate in
            attempts += 1
            try ClipboardInput.transact(text, store: board, validateReceiver: validate) { check, willSubmit in
                try check(); willSubmit(); sends += 1
                throw ComputerUseError.message("uncertain key result")
            }
        })
        XCTAssertThrowsError(try call(dispatcher)) {
            XCTAssertTrue($0.localizedDescription.contains("input may have occurred"))
            XCTAssertTrue($0.localizedDescription.contains("do not replay"))
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(board.text, "归档测试")
    }

    func testStaleWindowPreventsReceiverReadAndSubmission() {
        var attempts = 0
        let dispatcher = dispatcher(read: { _, _ in
            XCTFail("stale window must be rejected first")
            return AXUIElementCreateApplication(123)
        }, window: { _ in throw ComputerUseError.stateUnavailable("stale window") }, paste: { _, _, _, _ in
            attempts += 1
        })
        XCTAssertThrowsError(try call(dispatcher))
        XCTAssertEqual(attempts, 0)
    }

    func testCancellationAfterStagingRestoresClipboardWithoutInput() {
        // 模拟宿主在真正提交前取消，沿用 ClipboardInput 的事务收尾。
        let board = PasteTestClipboard()
        var sends = 0
        let dispatcher = dispatcher(read: { _, _ in
            if board.writes > 0 { throw CancellationError() }
            return AXUIElementCreateApplication(123)
        }, paste: { _, text, _, validate in
            try ClipboardInput.transact(text, store: board, validateReceiver: validate) { _, willSubmit in
                willSubmit(); sends += 1
            }
        })
        XCTAssertThrowsError(try call(dispatcher)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(board.text, "original")
    }

    func testPolicyUsesResolvedBundleIdentityAndKeepsOtherApplicationsUnchanged() {
        XCTAssertEqual(SkyPasteRoute.forApplication(bundleIdentifier: "com.apple.finder"), .focusedText)
        for bundle in [nil, "", "Finder", "com.apple.TextEdit", "com.google.Chrome", "com.kingsoft.wpsoffice.mac"] {
            XCTAssertEqual(SkyPasteRoute.forApplication(bundleIdentifier: bundle), .menuEquivalent)
        }
    }

    func testAlreadyCancelledTaskStopsBeforeSnapshotLookup() async {
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try ComputerUseService().pasteText(app: "no snapshot", text: "must not submit")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
    }
}

private final class PasteTestClipboard: ClipboardStore {
    var changeCount = 0
    var items = [ClipboardItem(values: [.string: Data("original".utf8)])]
    var writes = 0
    var text: String? {
        items.first?.values[.string].flatMap { String(data: $0, encoding: .utf8) }
    }

    func readItems() throws -> [ClipboardItem] {
        items
    }

    func clear() -> Int {
        items = []; changeCount += 1; return changeCount
    }

    func write(_ items: [ClipboardItem]) -> Bool {
        self.items = items; writes += 1; return true
    }

    func owns(_ token: String) -> Bool {
        items.first?.values[ClipboardInput.ownerType] == Data(token.utf8)
    }
}
