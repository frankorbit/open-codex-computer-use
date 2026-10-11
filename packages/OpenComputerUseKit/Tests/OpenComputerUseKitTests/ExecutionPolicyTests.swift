import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class ExecutionPolicyTests: XCTestCase {
    private let modeKey = "OPEN_COMPUTER_USE_EXECUTION_MODE"
    private let legacyKeys = [
        "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS",
        "OPEN_COMPUTER_USE_ALLOW_FOREGROUND_CLICKS",
        "OPEN_COMPUTER_USE_FOREGROUND_HOVER",
        "OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE",
        "OPEN_COMPUTER_USE_ACTION_READ_BACK",
        "OPEN_COMPUTER_USE_LIVE_PREVIEW"
    ]
    private var saved: [String: String] = [:]

    override func setUp() {
        super.setUp()
        for key in legacyKeys + [modeKey] {
            saved[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, key == "OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE" ? "foreground" : "1", 1)
        }
        setenv(modeKey, "background", 1)
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0", 1)
        setenv("OPEN_COMPUTER_USE_LIVE_PREVIEW", "0", 1)
    }

    override func tearDown() {
        for key in legacyKeys + [modeKey] {
            if let value = saved[key] {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        super.tearDown()
    }

    func testAbsentModePreservesLegacyOptInsAndUnknownValuesFailClosed() throws {
        XCTAssertEqual(try ExecutionPolicy.current(environment: [:]), .compatible)
        for value in ["BACKGROUND", " background "] {
            XCTAssertEqual(try ExecutionPolicy.current(environment: [modeKey: value]), .background)
        }
        for value in ["", "foreground", "compatibility", "backgroud"] {
            XCTAssertThrowsError(try ExecutionPolicy.current(environment: [modeKey: value]))
        }
        unsetenv(modeKey)
        let environment = ProcessInfo.processInfo.environment
        XCTAssertTrue(foregroundClicksEnabled(environment: environment))
        XCTAssertTrue(automaticForegroundClicksEnabled(environment: environment))
        XCTAssertTrue(globalPointerFallbacksEnabled(environment: environment))
        XCTAssertTrue(foregroundHoverEnabled(environment: environment))
        var submissions = 0
        try dispatchForegroundClick(validateTarget: {}, prepare: {}, validateReceiver: {}, submit: { submissions += 1 })
        XCTAssertEqual(submissions, 1)
    }

    func testSingleClickAuthorizationDoesNotLeakToOrdinaryRoutesOnSuccessOrFailure() throws {
        for fails in [false, true] {
            var calls: [String] = []
            do {
                try dispatchForegroundClick(authorization: .hostSingleClick,
                    validateTarget: { calls.append("target") }, prepare: { calls.append("prepare") },
                    validateReceiver: { calls.append("receiver") }, submit: {
                        calls.append("submit")
                        if fails { throw ComputerUseError.message("unknown input") }
                    })
                XCTAssertFalse(fails)
            } catch { XCTAssertTrue(fails) }
            XCTAssertEqual(calls, ["target", "prepare", "receiver", "submit"])
            XCTAssertThrowsError(try dispatchForegroundClick(
                validateTarget: { XCTFail("must remain blocked") }, prepare: {}, validateReceiver: {}, submit: {}))
            XCTAssertFalse(automaticForegroundClicksEnabled(environment: ProcessInfo.processInfo.environment))
            XCTAssertFalse(globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment))
            XCTAssertThrowsError(try ExecutionPolicy.current().requireAXAction("Raise"))
        }
    }

    func testSingleClickStillChecksReceiverAfterActivationAndDoesNotSubmitOnMismatch() {
        var calls: [String] = []
        XCTAssertThrowsError(try dispatchForegroundClick(authorization: .hostSingleClick,
            validateTarget: { calls.append("target") }, prepare: { calls.append("prepare") },
            validateReceiver: { throw ComputerUseError.message("changed window") },
            submit: { calls.append("submit") }))
        XCTAssertEqual(calls, ["target", "prepare"])
    }

    func testSingleClickInvalidPolicyReportsNoActivationOrInput() {
        setenv(modeKey, "invalid-policy", 1)
        XCTAssertThrowsError(try dispatchForegroundClick(authorization: .hostSingleClick,
            validateTarget: { XCTFail("policy failure must stop target lookup") },
            prepare: { XCTFail("must not activate") }, validateReceiver: {},
            submit: { XCTFail("must not submit") })) { error in
            guard let failure = error as? ForegroundClickFailure else {
                return XCTFail("Expected sanitized foreground failure")
            }
            XCTAssertEqual(failure.stage, .policy)
            XCTAssertEqual(failure.cause, .invalidArguments)
            XCTAssertFalse(failure.activationMayHaveOccurred)
            XCTAssertFalse(failure.inputMayHaveOccurred)
        }
    }

    func testSingleClickLeaseExpiryIdentityAndDefaultHostDenial() throws {
        let observation = ForegroundClickObservation(app: "test.editor", observedAt: 100)
        try observation.validate(app: "test.editor", now: 130)
        for time in [99.0, 130.01, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try observation.validate(app: "test.editor", now: time))
        }
        XCTAssertThrowsError(try observation.validate(app: "test.other", now: 101))
        let dispatcher = ComputerUseToolDispatcher()
        XCTAssertThrowsError(try dispatcher.callTool(name: "click_foreground_once", arguments: [
            "app": "test.editor", "x": 10, "y": 10, "purpose": "open_control",
        ])) { error in XCTAssertTrue(error.localizedDescription.contains("Host has not enabled")) }
        XCTAssertThrowsError(try InputSimulation.clickGlobally(at: .zero, button: .right, clickCount: 1, authorization: .hostSingleClick))
        XCTAssertThrowsError(try InputSimulation.clickGlobally(at: .zero, button: .left, clickCount: 2, authorization: .hostSingleClick))
    }

    func testStrictModeOverridesAllLegacyForegroundFlags() {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertFalse(foregroundClicksEnabled(environment: environment))
        XCTAssertFalse(automaticForegroundClicksEnabled(environment: environment))
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: environment))
        XCTAssertFalse(foregroundHoverEnabled(environment: environment))
        XCTAssertEqual(dragDeliveryPath(environment: environment), .appPost)
    }

    func testServiceAndDispatcherRejectExplicitForegroundBeforeSnapshotLookup() {
        let service = ComputerUseService()
        let dispatcher = ComputerUseToolDispatcher(service: service)
        let requests: [(String, [String: Any])] = [
            ("click", ["app": "missing", "x": 0, "y": 0, "click_method": "global"]),
            ("hover", ["app": "missing", "x": 0, "y": 0]),
            ("click", ["app": "missing", "popup_token": "old", "x": 0, "y": 0])
        ]
        for (name, arguments) in requests {
            XCTAssertThrowsError(try dispatcher.callTool(name: name, arguments: arguments)) { error in
                XCTAssertTrue(error.localizedDescription.contains("background execution mode"))
            }
        }
        XCTAssertThrowsError(try service.click(
            app: "missing", elementIndex: nil, x: 0, y: 0, clickCount: 1, mouseButton: "left", clickMethod: .global
        )) { error in XCTAssertTrue(error.localizedDescription.contains("background execution mode")) }
        XCTAssertThrowsError(try service.hover(app: "missing", arguments: [:]))
        XCTAssertThrowsError(try service.clickPopup(app: "missing", arguments: [:]))
    }

    func testUnknownModeRejectsEveryDispatcherEntryBeforeExecution() {
        setenv(modeKey, "typo", 1)
        let dispatcher = ComputerUseToolDispatcher()
        for tool in [
            "list_apps",
            "get_app_state",
            "click",
            "hover",
            "type_text",
            "press_key",
            "scroll",
            "drag",
            "set_value",
            "perform_secondary_action"
        ] {
            XCTAssertThrowsError(try dispatcher.callTool(name: tool, arguments: [:])) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unknown OPEN_COMPUTER_USE_EXECUTION_MODE"))
            }
        }
        XCTAssertThrowsError(try ComputerUseService().getAppState(app: "missing"))
        XCTAssertThrowsError(try ComputerUseService().typeText(app: "missing", text: "blocked"))
    }

    func testForegroundDispatchersRunNoCallbacksInStrictMode() {
        var callbacks = 0
        XCTAssertThrowsError(try dispatchForegroundClick(
            validateTarget: { callbacks += 1 }, prepare: { callbacks += 1 },
            validateReceiver: { callbacks += 1 }, submit: { callbacks += 1 }
        ))
        XCTAssertThrowsError(try dispatchForegroundHover(
            validateTarget: { callbacks += 1 }, prepare: { callbacks += 1 },
            validateReceiver: { callbacks += 1 }, submit: { callbacks += 1 },
            dwell: { callbacks += 1 }, readBack: { callbacks += 1 }
        ))
        XCTAssertThrowsError(try dispatchPopupClick(
            validate: { callbacks += 1 }, submit: { callbacks += 1 }, readBack: { callbacks += 1 }
        ))
        XCTAssertEqual(callbacks, 0)
    }

    func testGlobalPrimitivesRejectBeforeCreatingOrPostingEvents() {
        XCTAssertThrowsError(try InputSimulation.clickGlobally(at: .zero, button: .left, clickCount: 1))
        XCTAssertThrowsError(try InputSimulation.scrollGlobally(at: .zero, direction: "down", pages: 1))
        XCTAssertThrowsError(try InputSimulation.dragGlobally(from: .zero, to: CGPoint(x: 1, y: 1)))
        XCTAssertThrowsError(try InputSimulation.movePointerForHover(at: .zero))
        let app = RunningAppDescriptor(name: "test", bundleIdentifier: nil, pid: getpid(), runningApplication: .current)
        XCTAssertThrowsError(try InputSimulation.prepareAppForGlobalPointerInput(app))
        XCTAssertThrowsError(try InputSimulation.prepareWindowForForegroundClick(
            app,
            window: AXUIElementCreateApplication(getpid())
        ))
    }

    func testActivationRecoveryIsSkippedButCompatibleRecoveryStillExecutes() {
        var calls = 0
        XCTAssertFalse(performWindowRecovery(
            policy: .background,
            requested: .allowActivation,
            recover: { calls += 1; return true }
        ))
        XCTAssertFalse(performWindowRecovery(
            policy: .compatible,
            requested: .readOnly,
            recover: { calls += 1; return true }
        ))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(performWindowRecovery(
            policy: .compatible,
            requested: .allowActivation,
            recover: { calls += 1; return true }
        ))
        XCTAssertEqual(calls, 1)
    }

    func testAXPressAndBackgroundCoordinateFallbackRemainUsableButRaiseIsBlocked() throws {
        var actions: [String] = []
        XCTAssertThrowsError(try executeAXAction(named: kAXRaiseAction, availableActions: [kAXRaiseAction], perform: {
            actions.append("raise"); return .success
        }))
        XCTAssertEqual(try executeAXAction(named: kAXPressAction, availableActions: [kAXPressAction], perform: {
            actions.append("press"); return .success
        }), .completed)
        try dispatchCoordinateClick(
            at: .zero, target: nil, button: .left, clickCount: 1, validateWindow: {},
            performAX: { _ in XCTFail("unexpected AX"); return .failure },
            performMouse: {
                XCTAssertEqual(coordinateMouseMethod(
                    button: .left,
                    clickCount: 1,
                    globalEnabled: automaticForegroundClicksEnabled(environment: ProcessInfo.processInfo.environment)
                ), .skyClick)
                actions.append("sky")
            }
        )
        XCTAssertEqual(actions, ["press", "sky"])
    }

    func testAppPostRejectsWrongWindowWithoutInputAndDoesNotRetryUnknownDelivery() throws {
        var attempts = 0
        XCTAssertThrowsError(try dispatchAppPostInput(policy: .background, validateReceiver: {
            try validateCoordinateAppPostReceiver(focusedWindowMatches: false)
        }, submit: { attempts += 1 }))
        XCTAssertEqual(attempts, 0)
        XCTAssertThrowsError(try dispatchAppPostInput(policy: .background, validateReceiver: {
            try validateCoordinateAppPostReceiver(focusedWindowMatches: true)
        }, submit: { attempts += 1; throw ComputerUseError.message("unknown") }))
        XCTAssertEqual(attempts, 1)
        try dispatchAppPostInput(policy: .compatible, validateReceiver: { XCTFail("legacy receiver behavior changed") },
                                 submit: { attempts += 1 })
        XCTAssertEqual(attempts, 2)
    }

    func testAppPostRevalidatesWindowAfterOptionalAXLookupBeforeInput() throws {
        for changesDuringLookup in [false, true] {
            var phases: [String] = []
            var changed = false
            let operation = {
                try dispatchAppPostInput(policy: .background, validateReceiver: {
                    try validateCoordinateAppPostTarget(validateWindow: {
                        phases.append("window")
                        if changed { throw ComputerUseError.stateUnavailable("window changed") }
                    }, readFocusedWindowMatch: {
                        phases.append("lookup")
                        changed = changesDuringLookup
                        return nil
                    })
                }, submit: { phases.append("input") })
            }
            if changesDuringLookup {
                XCTAssertThrowsError(try operation())
                XCTAssertEqual(phases, ["window", "lookup", "window"])
            } else {
                try operation()
                XCTAssertEqual(phases, ["window", "lookup", "window", "input"])
            }
        }
    }

    func testBackgroundAppPostAcceptsOptionalAXAndNeverRetriesUnknownInput() throws {
        for matches: Bool? in [true, nil] {
            var submissions = 0
            try dispatchAppPostInput(policy: .background, validateReceiver: {
                try validateCoordinateAppPostReceiver(focusedWindowMatches: matches)
            }, submit: { submissions += 1 })
            XCTAssertEqual(submissions, 1)
        }
        var submissions = 0
        XCTAssertThrowsError(try dispatchAppPostInput(policy: .background, validateReceiver: {
            try validateCoordinateAppPostReceiver(focusedWindowMatches: false)
        }, submit: { submissions += 1 }))
        XCTAssertEqual(submissions, 0)
        XCTAssertThrowsError(try dispatchAppPostInput(policy: .background, validateReceiver: {
            try validateCoordinateAppPostReceiver(focusedWindowMatches: nil)
        }, submit: { submissions += 1; throw ComputerUseError.message("unknown input") }))
        XCTAssertEqual(submissions, 1)
    }

    func testStrictServiceKeepsKeyboardDispatchAndLiveReceiverValidation() throws {
        let receiver = AXUIElementCreateApplication(getpid())
        let snapshot = AppSnapshot(
            app: RunningAppDescriptor(
                name: "Editor",
                bundleIdentifier: "test.editor",
                pid: getpid(),
                runningApplication: .current
            ),
            windowTitle: "Test", windowBounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            targetWindowID: 42, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil,
            selectedText: nil, windowElement: receiver, elements: [:]
        )
        var reads = 0
        var sends = 0
        let service = ComputerUseService(snapshots: ["editor": snapshot], keyboardInputBackend: KeyboardInputBackend(
            readReceiver: { _, _ in reads += 1; return receiver },
            typeText: { _, _, validate in try validate(); sends += 1 },
            pressKey: { _, _, validate in try validate(); sends += 1 }
        ))
        _ = try service.typeText(app: "editor", text: "allowed")
        _ = try service.pressKey(app: "editor", key: "Left")
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(reads, 3)
    }
}
