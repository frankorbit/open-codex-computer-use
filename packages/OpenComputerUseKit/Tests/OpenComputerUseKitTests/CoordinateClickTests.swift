import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class CoordinateClickTests: XCTestCase {
    private let point = CGPoint(x: 250, y: 400)
    private let buttonFrame = CGRect(x: 200, y: 350, width: 100, height: 100)

    private func target(
        role: String = kAXButtonRole,
        frame: CGRect? = nil,
        actions: [String] = [kAXPressAction],
        belongsToWindow: Bool = true
    ) -> CoordinateClickTarget {
        CoordinateClickTarget(
            role: role,
            frame: frame ?? buttonFrame,
            actions: actions,
            belongsToWindow: belongsToWindow
        )
    }

    private func dispatch(
        _ target: CoordinateClickTarget?,
        button: MouseButtonKind = .left,
        clickCount: Int = 1,
        axResult: AXError = .success
    ) throws -> [String] {
        var events: [String] = []
        try dispatchCoordinateClick(
            at: point, target: target, button: button, clickCount: clickCount,
            validateWindow: {}, performAX: { events.append($0); return axResult },
            performMouse: { events.append("mouse") }
        )
        return events
    }

    func testCustomCanvasWindowNeverSearchesCloseMinimizeOrZoomDescendants() throws {
        // 即使容器本身声称支持 Press，也不能从点击区域跳到窗口子控件。
        for role in [kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, kAXListRole, kAXTableRole] {
            XCTAssertEqual(try dispatch(target(role: role)), ["mouse"], role)
        }
    }

    func testDirectButtonUsesOnlyItsOwnPress() throws {
        XCTAssertEqual(try dispatch(target(actions: [kAXRaiseAction, kAXPressAction])), [kAXPressAction])
    }

    func testRaiseOnlyControlUsesMouse() throws {
        XCTAssertEqual(try dispatch(target(actions: [kAXRaiseAction])), ["mouse"])
        XCTAssertEqual(try dispatch(nil), ["mouse"])
    }

    func testWindowControlCanOnlyBePressedAtItsOwnCoordinates() throws {
        let closeFrame = CGRect(x: 8, y: 8, width: 16, height: 16)
        let close = target(frame: closeFrame)
        XCTAssertEqual(try dispatch(close), ["mouse"])
        var events: [String] = []
        try dispatchCoordinateClick(
            at: CGPoint(x: 16, y: 16), target: close, button: .left, clickCount: 1,
            validateWindow: {}, performAX: { events.append($0); return .success },
            performMouse: { events.append("mouse") }
        )
        XCTAssertEqual(events, [kAXPressAction])
    }

    func testDifferentOrUnverifiedWindowSendsNoInput() {
        var events: [String] = []
        XCTAssertThrowsError(try dispatchCoordinateClick(
            at: point, target: target(belongsToWindow: false), button: .left, clickCount: 1,
            validateWindow: {}, performAX: { events.append($0); return .success },
            performMouse: { events.append("mouse") }
        ))
        XCTAssertTrue(events.isEmpty)
    }

    func testRightClickOnlyUsesShowMenu() throws {
        XCTAssertEqual(try dispatch(target(), button: .right), ["mouse"])
        XCTAssertEqual(try dispatch(target(actions: [kAXShowMenuAction]), button: .right), [kAXShowMenuAction])
    }

    func testDoubleAndMiddleClicksPreserveMouseSemantics() throws {
        XCTAssertEqual(try dispatch(target(), clickCount: 2), ["mouse"])
        XCTAssertEqual(try dispatch(target(), button: .middle), ["mouse"])
    }

    func testAXErrorsNeverReplayOrTryAnotherAction() {
        for error in [AXError.cannotComplete, .actionUnsupported, .invalidUIElement, .failure] {
            var events: [String] = []
            XCTAssertThrowsError(try dispatchCoordinateClick(
                at: point, target: target(actions: [kAXPressAction, kAXConfirmAction]), button: .left, clickCount: 1,
                validateWindow: {}, performAX: { events.append($0); return error },
                performMouse: { events.append("mouse") }
            ))
            XCTAssertEqual(events, [kAXPressAction])
        }
    }

    func testThrownAXFailureNeverFallsBack() {
        var mouseCount = 0
        XCTAssertThrowsError(try dispatchCoordinateClick(
            at: point, target: target(), button: .left, clickCount: 1,
            validateWindow: {}, performAX: { _ in throw ComputerUseError.message("transport failed") },
            performMouse: { mouseCount += 1 }
        ))
        XCTAssertEqual(mouseCount, 0)
    }

    func testScreenshotScaleAppliedOnceBeforeGlobalWindowOffset() {
        let bounds = CGRect(x: -1440, y: 120, width: 1440, height: 960)
        for size in [CGSize(width: 2880, height: 1920), CGSize(width: 1280, height: 853), bounds.size] {
            let screenshotPoint = CGPoint(x: size.width / 4, y: size.height / 2)
            let local = screenshotPixelToWindowPoint(screenshotPoint, screenshotPixelSize: size, windowBounds: bounds)
            XCTAssertEqual(local.x, 360, accuracy: 0.001)
            XCTAssertEqual(local.y, 480, accuracy: 0.001)
            let global = globalPointFromWindowPoint(local, windowBounds: bounds)
            XCTAssertEqual(global.x, -1080, accuracy: 0.001)
            XCTAssertEqual(global.y, 600, accuracy: 0.001)
        }
    }
}

final class CoordinateClickServiceTests: XCTestCase {
    private var previousEnvironment: [String: String] = [:]
    private let environmentKeys = ["OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_VISUAL_CURSOR"]

    override func setUp() {
        super.setUp()
        for key in environmentKeys {
            previousEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "0", 1)
        }
    }

    override func tearDown() {
        for key in environmentKeys {
            if let value = previousEnvironment[key] { setenv(key, value, 1) } else { unsetenv(key) }
        }
        super.tearDown()
    }

    private func snapshot(imageSize: CGSize) throws -> AppSnapshot {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(imageSize.width), pixelsHigh: Int(imageSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let app = RunningAppDescriptor(
            name: "Mock Canvas",
            bundleIdentifier: "test.canvas",
            pid: getpid(),
            runningApplication: .current
        )
        let close = ElementRecord(index: 11, identifier: nil, element: nil,
                                  localFrame: CGRect(x: 8, y: 8, width: 16, height: 16),
                                  role: kAXButtonRole, rawActions: [kAXPressAction], prettyActions: [kAXPressAction])
        return AppSnapshot(
            app: app, windowTitle: nil, windowBounds: CGRect(x: -1440, y: 120, width: 1440, height: 960),
            targetWindowID: nil, targetWindowLayer: nil, screenshotData: png, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: [11: close]
        )
    }

    func testActualCoordinateClickScalesOnceAndDoesNotSelectCloseDescendant() throws {
        for size in [CGSize(width: 2880, height: 1920), CGSize(width: 1280, height: 853)] {
            let state = try snapshot(imageSize: size)
            var queried: [CGPoint] = []
            var mousePoints: [CGPoint] = []
            var axActions: [String] = []
            let backend = CoordinateClickBackend(
                validateWindow: { _, _ in },
                hitTest: { point, _ in
                    queried.append(point)
                    return CoordinateClickHit(
                        target: CoordinateClickTarget(
                            role: kAXWindowRole,
                            frame: CGRect(origin: .zero, size: CGSize(width: 1440, height: 960)),
                            actions: [kAXRaiseAction, kAXPressAction],
                            belongsToWindow: true
                        ),
                        performAX: { axActions.append($0); return .success }
                    )
                },
                performMouse: { point, _, count, _ in mousePoints.append(point); XCTAssertEqual(count, 1) }
            )
            let service = ComputerUseService(snapshots: ["test.canvas": state], coordinateClickBackend: backend)
            _ = try service.click(
                app: "test.canvas",
                elementIndex: nil,
                x: Double(size.width / 4),
                y: Double(size.height / 2),
                clickCount: 1,
                mouseButton: "left"
            )
            XCTAssertEqual(queried, [CGPoint(x: -1080, y: 600)])
            XCTAssertEqual(mousePoints, queried)
            XCTAssertTrue(axActions.isEmpty)
        }
    }

    func testActualCoordinateClickWithoutAXUsesValidatedWindow() throws {
        let state = try snapshot(imageSize: CGSize(width: 1280, height: 853))
        var mouseCount = 0
        var validations = 0
        let backend = CoordinateClickBackend(
            validateWindow: { _, _ in validations += 1 },
            hitTest: { _, _ in nil }, performMouse: { _, _, _, _ in mouseCount += 1 }
        )
        let service = ComputerUseService(snapshots: ["test.canvas": state], coordinateClickBackend: backend)
        _ = try service.click(app: "test.canvas", elementIndex: nil, x: 250, y: 400, clickCount: 1, mouseButton: "left")
        XCTAssertEqual(mouseCount, 1)
        XCTAssertEqual(validations, 2)
    }

    func testServiceFallsBackFromUnavailableHitTestOnlyAfterWindowRevalidation() throws {
        let state = try snapshot(imageSize: CGSize(width: 1280, height: 853))
        for result in [AXError.cannotComplete, .attributeUnsupported, .invalidUIElement, .failure] {
            var phases: [String] = []
            let backend = CoordinateClickBackend(
                validateWindow: { _, _ in phases.append("window") },
                hitTest: { _, _ in
                    phases.append("lookup")
                    XCTAssertFalse(try coordinateHitTestHasElement(result))
                    return nil
                },
                performMouse: { _, _, _, _ in phases.append("mouse") }
            )
            let service = ComputerUseService(snapshots: ["test.canvas": state], coordinateClickBackend: backend)
            _ = try service.click(
                app: "test.canvas",
                elementIndex: nil,
                x: 250,
                y: 400,
                clickCount: 1,
                mouseButton: "left"
            )
            XCTAssertEqual(phases, ["window", "lookup", "window", "mouse"])
        }
    }

    func testUnavailableHitTestDoesNotBypassChangedWindowOrPermissionFailure() throws {
        let state = try snapshot(imageSize: CGSize(width: 1280, height: 853))
        for result in [AXError.cannotComplete, .apiDisabled] {
            var validations = 0
            let backend = CoordinateClickBackend(
                validateWindow: { _, _ in
                    validations += 1
                    if validations == 2 { throw ComputerUseError.stateUnavailable("window changed") }
                },
                hitTest: { _, _ in
                    _ = try coordinateHitTestHasElement(result)
                    return nil
                },
                performMouse: { _, _, _, _ in XCTFail("must not send") }
            )
            let service = ComputerUseService(snapshots: ["test.canvas": state], coordinateClickBackend: backend)
            XCTAssertThrowsError(try service.click(
                app: "test.canvas", elementIndex: nil, x: 250, y: 400, clickCount: 1, mouseButton: "left"
            ))
            XCTAssertEqual(validations, result == .apiDisabled ? 1 : 2)
        }
    }

    func testWindowChangingDuringHitTestSendsNothing() throws {
        let state = try snapshot(imageSize: CGSize(width: 1280, height: 853))
        var validations = 0
        var mouseCount = 0
        let backend = CoordinateClickBackend(
            validateWindow: { _, _ in
                validations += 1
                if validations == 2 { throw ComputerUseError.stateUnavailable("window moved") }
            },
            hitTest: { _, _ in nil }, performMouse: { _, _, _, _ in mouseCount += 1 }
        )
        let service = ComputerUseService(snapshots: ["test.canvas": state], coordinateClickBackend: backend)
        XCTAssertThrowsError(try service.click(
            app: "test.canvas",
            elementIndex: nil,
            x: 250,
            y: 400,
            clickCount: 1,
            mouseButton: "left"
        ))
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(mouseCount, 0)
    }

    func testMissingWindowFailsBeforeHitTest() throws {
        let state = try snapshot(imageSize: CGSize(width: 1280, height: 853))
        var queries = 0
        var mouseCount = 0
        let backend = CoordinateClickBackend(
            validateWindow: { _, _ in throw ComputerUseError.stateUnavailable("window missing") },
            hitTest: { _, _ in queries += 1; return nil }, performMouse: { _, _, _, _ in mouseCount += 1 }
        )
        let service = ComputerUseService(snapshots: ["test.canvas": state], coordinateClickBackend: backend)
        XCTAssertThrowsError(try service.click(
            app: "test.canvas",
            elementIndex: nil,
            x: 250,
            y: 400,
            clickCount: 1,
            mouseButton: "left"
        ))
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(mouseCount, 0)
    }
}

final class ForegroundClickTests: XCTestCase {
    func testClickPolicyDoesNotEnableGlobalDragOrScrollGate() throws {
        let environment = ["OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE": "foreground"]
        XCTAssertTrue(foregroundClicksEnabled(environment: environment))
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: environment))
        XCTAssertEqual(dragDeliveryPath(environment: environment), .appPost)
        XCTAssertNoThrow(try validateClickMethod(.global, hasElementIndex: false, environment: environment))
        XCTAssertFalse(foregroundClicksEnabled(environment: [:]))
        XCTAssertFalse(foregroundClicksEnabled(environment: ["OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE": "invalid"]))
    }

    func testExplicitForegroundPermissionDoesNotChangeAutomaticBackgroundRouting() throws {
        let environment = [
            "OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE": "background",
            "OPEN_COMPUTER_USE_ALLOW_FOREGROUND_CLICKS": "1"
        ]
        XCTAssertTrue(foregroundClicksEnabled(environment: environment))
        XCTAssertFalse(automaticForegroundClicksEnabled(environment: environment))
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: environment))
        XCTAssertNoThrow(try validateClickMethod(.global, hasElementIndex: false, environment: environment))
        XCTAssertEqual(
            coordinateMouseMethod(button: .left, clickCount: 1,
                                  globalEnabled: automaticForegroundClicksEnabled(environment: environment)),
            .skyClick
        )
        XCTAssertEqual(coordinateMouseMethod(button: .right, clickCount: 1, globalEnabled: false), .appPost)
        XCTAssertFalse(
            automaticForegroundClicksEnabled(environment: ["OPEN_COMPUTER_USE_ALLOW_FOREGROUND_CLICKS": "1"])
        )
        XCTAssertTrue(
            automaticForegroundClicksEnabled(environment: ["OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE": "foreground"])
        )
    }

    func testForegroundClickValidatesAfterActivationAndSubmitsOnce() throws {
        var phases: [String] = []
        try dispatchForegroundClick(
            validateTarget: { phases.append("target") }, prepare: { phases.append("activate") },
            validateReceiver: { phases.append("receiver") }, submit: { phases.append("input") }
        )
        XCTAssertEqual(phases, ["target", "activate", "receiver", "input"])
    }

    func testChangedGeometryOrReceiverAfterActivationPreventsInput() {
        let oldBounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        var currentBounds = oldBounds
        var inputs = 0
        XCTAssertThrowsError(try dispatchForegroundClick(
            validateTarget: {}, prepare: { currentBounds.origin.x += 1 },
            validateReceiver: {
                try validateCoordinateWindow(
                    windowID: 7, pid: 123, bounds: oldBounds, point: CGPoint(x: 30, y: 40),
                    windows: [[kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: 123,
                               kCGWindowBounds as String: currentBounds.dictionaryRepresentation,
                               kCGWindowIsOnscreen as String: true]],
                    requireUnoccludedPoint: true, spacesForWindow: { _ in [1] }
                )
            }, submit: { inputs += 1 }
        ))
        XCTAssertEqual(inputs, 0)
    }

    func testActivationFailureAndUnknownInputNeverRetry() throws {
        for failure in ["target", "activate", "receiver", "input"] {
            var phases: [String] = []
            func perform(_ phase: String) throws {
                phases.append(phase)
                if phase == failure { throw ComputerUseError.message("unavailable or unknown") }
            }
            XCTAssertThrowsError(try dispatchForegroundClick(
                validateTarget: { try perform("target") }, prepare: { try perform("activate") },
                validateReceiver: { try perform("receiver") }, submit: { try perform("input") }
            ))
            let expected = try Array(["target", "activate", "receiver", "input"].prefix(through: XCTUnwrap([
                "target",
                "activate",
                "receiver",
                "input"
            ].firstIndex(of: failure))))
            XCTAssertEqual(phases, expected)
        }
    }
}
