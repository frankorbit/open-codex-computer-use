import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class KeyboardReceiverAXReaderTests: XCTestCase {
    func testFocusedWindowReadOverridesInheritedObservationTimeoutWithoutRetry() throws {
        let app = AXUIElementCreateApplication(123)
        var clock = 10.0
        var inheritedTimeout: Float = 0.1
        var settings: [Float] = []
        var reads = 0
        let reader = KeyboardReceiverAXReader(
            now: { clock },
            setTimeout: { source, timeout in
                XCTAssertTrue(CFEqual(source, app))
                settings.append(timeout)
                inheritedTimeout = timeout == 0 ? 0.1 : timeout
                return .success
            },
            copyValue: { _, attribute in
                XCTAssertEqual(attribute, kAXFocusedWindowAttribute)
                reads += 1
                clock += 0.15
                return inheritedTimeout > 0.15 ? (.success, app) : (.cannotComplete, nil)
            }
        )
        XCTAssertTrue(try CFEqual(reader.element(app, attribute: kAXFocusedWindowAttribute), app))
        XCTAssertEqual(settings, [axInputMessagingTimeout, 0])
        XCTAssertEqual(inheritedTimeout, 0.1)
        XCTAssertEqual(reads, 1)
    }

    func testAllReceiverAttributesShareOneBudget() throws {
        var clock = 0.0
        var settings: [Float] = []
        let reader = KeyboardReceiverAXReader(now: { clock }, setTimeout: { _, timeout in
            settings.append(timeout); return .success
        })
        let app = AXUIElementCreateApplication(123)
        _ = try reader.query(app, attribute: kAXFocusedWindowAttribute) { clock += 0.5; return .success }
        _ = try reader.query(app, attribute: kAXFocusedUIElementAttribute) { clock += 0.5; return .success }
        XCTAssertEqual(settings, [2, 0, 1.5, 0])
        clock = 2
        XCTAssertThrowsError(try reader.query(app, attribute: kAXRoleAttribute) {
            XCTFail("expired budget must not query"); return .success
        })
        XCTAssertEqual(settings.count, 4)
    }

    func testLateSuccessStillStopsAndRestoresTimeout() {
        var clock = 0.0
        var settings: [Float] = []
        let reader = KeyboardReceiverAXReader(now: { clock }, setTimeout: { _, timeout in
            settings.append(timeout); return .success
        })
        let app = AXUIElementCreateApplication(123)
        XCTAssertThrowsError(try reader.query(app, attribute: kAXFocusedWindowAttribute) {
            clock = 2.1; return .success
        })
        XCTAssertEqual(settings, [2, 0])
    }

    func testAXFailuresRemainFailuresWithoutRetryOrFallback() {
        for code: AXError in [.cannotComplete, .apiDisabled, .invalidUIElement, .failure, .illegalArgument] {
            var reads = 0
            var settings: [Float] = []
            let reader = KeyboardReceiverAXReader(now: { 0 }, setTimeout: { _, timeout in
                settings.append(timeout); return .success
            }, copyValue: { _, _ in reads += 1; return (code, nil) })
            let app = AXUIElementCreateApplication(123)
            XCTAssertThrowsError(try reader.element(app, attribute: kAXFocusedWindowAttribute)) {
                XCTAssertTrue(String(describing: $0).contains(String(code.rawValue)))
                XCTAssertTrue(String(describing: $0).contains(kAXFocusedWindowAttribute))
            }
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(settings, [2, 0])
        }
    }

    func testOptionalAbsenceCannotSatisfyRequiredFocusedWindow() {
        for code: AXError in [.noValue, .attributeUnsupported] {
            let reader = KeyboardReceiverAXReader(
                setTimeout: { _, _ in .success }, copyValue: { _, _ in (code, nil) }
            )
            XCTAssertNil(try reader.value(AXUIElementCreateApplication(123), attribute: kAXRoleDescriptionAttribute))
            XCTAssertThrowsError(try reader.element(
                AXUIElementCreateApplication(123),
                attribute: kAXFocusedWindowAttribute
            ))
        }
    }

    func testCancellationBeforeReadSendsNoQuery() {
        let reader = KeyboardReceiverAXReader(checkCancellation: { throw CancellationError() }, setTimeout: { _, _ in
            XCTFail("cancelled before preparation"); return .success
        })
        let app = AXUIElementCreateApplication(123)
        XCTAssertThrowsError(try reader.query(app, attribute: kAXFocusedWindowAttribute) {
            XCTFail("cancelled before read"); return .success
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellationDuringReadRestoresTimeoutAndRejectsSuccess() {
        var cancelled = false
        var settings: [Float] = []
        let reader = KeyboardReceiverAXReader(now: { 0 }, checkCancellation: {
            if cancelled { throw CancellationError() }
        }, setTimeout: { _, timeout in settings.append(timeout); return .success })
        let app = AXUIElementCreateApplication(123)
        XCTAssertThrowsError(try reader.query(app, attribute: kAXFocusedWindowAttribute) {
            cancelled = true; return .success
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(settings, [2, 0])
    }

    func testTimeoutSetupFailureDoesNotQueryAndRestoreFailureDoesNotPass() {
        for failSetup in [true, false] {
            var queries = 0
            let reader = KeyboardReceiverAXReader(setTimeout: { _, timeout in
                (timeout > 0) == failSetup ? .invalidUIElement : .success
            })
            let app = AXUIElementCreateApplication(123)
            XCTAssertThrowsError(try reader.query(app, attribute: kAXFocusedWindowAttribute) {
                queries += 1; return .success
            })
            XCTAssertEqual(queries, failSetup ? 0 : 1)
        }
    }
}
