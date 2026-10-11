import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class KeyboardReceiverTests: XCTestCase {
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

    private func snapshot() -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(
                name: "Editor",
                bundleIdentifier: "test.editor",
                pid: getpid(),
                runningApplication: .current
            ),
            windowTitle: "Test", windowBounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            targetWindowID: 42, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: AXUIElementCreateApplication(123),
            selectedText: nil, windowElement: nil, elements: [:]
        )
    }

    func testClickThenTypeUsesLiveFocusEvenWithReadbackDisabledAndStaleSnapshotFocus() throws {
        let live = AXUIElementCreateApplication(getpid())
        var reads = 0
        var typed: [String] = []
        let backend = KeyboardInputBackend(
            readReceiver: { _, editable in
                XCTAssertTrue(editable)
                reads += 1
                return live
            },
            typeText: { target, text, validate in
                XCTAssertEqual(target.windowID, 42)
                try validate()
                typed.append(text)
            },
            pressKey: { _, _, _ in XCTFail("unexpected key delivery") }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        _ = try service.typeText(app: "editor", text: "中文\ninsert at caret")
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(typed, ["中文\ninsert at caret"])
    }

    func testFocusChangingWhileWindowBecomesKeyPreventsTextAndDoesNotRetry() {
        var reads = 0
        var attempts = 0
        var sent = 0
        let backend = KeyboardInputBackend(
            readReceiver: { _, _ in
                reads += 1
                return AXUIElementCreateApplication(reads == 1 ? 123 : 456)
            },
            typeText: { _, _, validate in attempts += 1; try validate(); sent += 1 },
            pressKey: { _, _, _ in XCTFail("unexpected fallback") }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        XCTAssertThrowsError(try service.typeText(app: "editor", text: "do not send"))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sent, 0)
    }

    func testUnknownDeliveryDoesNotRetryOrReplaceValue() {
        var attempts = 0
        let backend = KeyboardInputBackend(
            readReceiver: { _, _ in AXUIElementCreateApplication(123) },
            typeText: { _, _, validate in
                try validate()
                attempts += 1
                throw ComputerUseError.message("input may have occurred")
            },
            pressKey: { _, _, _ in XCTFail("unexpected fallback") }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        XCTAssertThrowsError(try service.typeText(app: "editor", text: "once"))
        XCTAssertEqual(attempts, 1)
    }

    func testNoneditableOrMissingLiveFocusSendsNoTextEvenWithCachedFocus() {
        var attempts = 0
        let backend = KeyboardInputBackend(
            readReceiver: { _, _ in throw ComputerUseError.stateUnavailable("missing live focus") },
            typeText: { _, _, _ in attempts += 1 }, pressKey: { _, _, _ in attempts += 1 }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        XCTAssertThrowsError(try service.typeText(app: "editor", text: "blocked"))
        XCTAssertEqual(attempts, 0)
    }

    func testKeyboardShortcutValidatesWindowInsideDelivery() throws {
        var phases: [String] = []
        let backend = KeyboardInputBackend(
            readReceiver: { _, editable in
                XCTAssertFalse(editable)
                phases.append("validate window")
                return AXUIElementCreateApplication(123)
            },
            typeText: { _, _, _ in XCTFail("unexpected text delivery") },
            pressKey: { _, _, validate in
                phases.append("prepare window")
                try validate()
                phases.append("send key")
            }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        _ = try service.pressKey(app: "editor", key: "CMD+N")
        XCTAssertEqual(phases, ["prepare window", "validate window", "send key"])
    }

    func testExplicitSkyKeyDoesNotRequireAXTextOrWindowFocus() throws {
        var sent: [String] = []
        var validations = 0
        let backend = KeyboardInputBackend(
            readReceiver: { _, _ in
                XCTFail("explicit sky_key must not require AX focus"); throw ComputerUseError
                    .stateUnavailable("AX absent")
            },
            typeText: { _, text, validate in try validate(); sent.append(text) },
            pressKey: { _, key, validate in try validate(); sent.append(key) },
            validateWindow: { _ in validations += 1 },
            pasteText: { _, text, validate in try validate(); sent.append("paste:" + text) }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        _ = try service.typeText(app: "editor", text: "Uber", keyMethod: .skyKey)
        _ = try service.pressKey(app: "editor", key: "Return", keyMethod: .skyKey)
        _ = try service.pasteText(app: "editor", text: "中文")
        XCTAssertEqual(sent, ["Uber", "Return", "paste:中文"])
        XCTAssertEqual(validations, 5)
    }

    func testExplicitSkyKeyRejectsStaleWindowWithoutInput() {
        var sends = 0
        let backend = KeyboardInputBackend(
            readReceiver: { _, _ in XCTFail("unexpected AX validation"); return AXUIElementCreateApplication(123) },
            typeText: { _, _, validate in try validate(); sends += 1 },
            pressKey: { _, _, validate in try validate(); sends += 1 },
            validateWindow: { _ in throw ComputerUseError.stateUnavailable("stale target") },
            pasteText: { _, _, validate in try validate(); sends += 1 }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        XCTAssertThrowsError(try service.typeText(app: "editor", text: "blocked", keyMethod: .skyKey))
        XCTAssertThrowsError(try service.pressKey(app: "editor", key: "Return", keyMethod: .skyKey))
        XCTAssertThrowsError(try service.pasteText(app: "editor", text: "blocked"))
        XCTAssertEqual(sends, 0)
    }

    func testExplicitWindowChangedDuringPreparationStopsBeforeDelivery() {
        var checks = 0
        var sends = 0
        let backend = KeyboardInputBackend(
            readReceiver: { _, _ in XCTFail("unexpected AX check"); return AXUIElementCreateApplication(123) },
            typeText: { _, _, validate in try validate(); sends += 1 },
            pressKey: { _, _, _ in XCTFail("unexpected fallback") },
            validateWindow: { _ in
                checks += 1
                if checks > 1 { throw ComputerUseError.stateUnavailable("target changed") }
            }
        )
        let service = ComputerUseService(snapshots: ["editor": snapshot()], keyboardInputBackend: backend)
        XCTAssertThrowsError(try service.typeText(app: "editor", text: "once", keyMethod: .skyKey))
        XCTAssertEqual(sends, 0)
    }

    func testEditableRolesExcludeDisabledFieldsAndNonTextControls() throws {
        for role in [kAXTextFieldRole, kAXTextAreaRole, "AXTextView"] {
            XCTAssertNoThrow(try validateEditableKeyboardReceiver(role: role, description: nil, enabled: true))
            XCTAssertThrowsError(try validateEditableKeyboardReceiver(role: role, description: nil, enabled: false))
        }
        for role in [kAXSliderRole, kAXCheckBoxRole, "AXWebArea"] {
            XCTAssertThrowsError(try validateEditableKeyboardReceiver(role: role, description: nil, enabled: true))
        }
    }

    func testEditableComboAndExplicitReadOnlyStates() throws {
        XCTAssertNoThrow(try validateEditableKeyboardReceiver(
            role: kAXComboBoxRole, description: "组合框", enabled: true, valueSettable: true
        ))
        XCTAssertNoThrow(try validateEditableKeyboardReceiver(
            role: kAXComboBoxRole, description: "combo box", enabled: true, editable: true
        ))
        XCTAssertThrowsError(try validateEditableKeyboardReceiver(
            role: kAXComboBoxRole, description: "combo box", enabled: true
        ))
        XCTAssertThrowsError(try validateEditableKeyboardReceiver(
            role: kAXTextAreaRole, description: nil, enabled: true, readOnly: true, valueSettable: true
        ))
        XCTAssertThrowsError(try validateEditableKeyboardReceiver(
            role: kAXTextFieldRole, description: nil, enabled: true, editable: false
        ))
        XCTAssertThrowsError(try validateEditableKeyboardReceiver(
            role: kAXSliderRole, description: nil, enabled: true, valueSettable: true
        ))
    }

    func testTextStopsWhenFocusChangesBetweenChunksWithoutReplayingPrefix() {
        var sent: [[UniChar]] = []
        var checks = 0
        XCTAssertThrowsError(try deliverKeyboardTextChunks([[65], [66], [67]], validateReceiver: {
            checks += 1
            if checks == 2 { throw ComputerUseError.stateUnavailable("no text was sent") }
        }, submit: { sent.append($0) })) { error in
            XCTAssertTrue(error.localizedDescription.contains("some text may already"))
            XCTAssertFalse(error.localizedDescription.contains("no text was sent"))
        }
        XCTAssertEqual(sent, [[65]])
        XCTAssertEqual(checks, 2)
    }

    func testTextInitialValidationFailureSendsNothingAndPreservesError() {
        var sends = 0
        XCTAssertThrowsError(try deliverKeyboardTextChunks([[65]], validateReceiver: {
            throw ComputerUseError.stateUnavailable("no text was sent")
        }, submit: { _ in sends += 1 })) { error in
            XCTAssertTrue(error.localizedDescription.contains("no text was sent"))
        }
        XCTAssertEqual(sends, 0)
    }

    func testFocusSummarySurvivesTreeTruncationWithoutInventingIndex() {
        XCTAssertEqual(
            focusedElementSummary(rendered: "42 text entry", role: "AXTextArea", hasFocusedElement: true),
            "42 text entry"
        )
        XCTAssertEqual(
            focusedElementSummary(rendered: nil, role: "AXTextArea", hasFocusedElement: true),
            "AXTextArea (outside the rendered tree; no element index available)"
        )
        XCTAssertNil(focusedElementSummary(rendered: nil, role: nil, hasFocusedElement: false))
    }
}
