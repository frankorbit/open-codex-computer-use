import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class HoverPopupAXReadTests: XCTestCase {
    func testAXFailuresPreserveCodeAndNeverRetryOrAcceptReturnedValue() {
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .attributeUnsupported, .noValue] {
            var copies = 0
            var reports: [HoverPopupAXRead.Failure] = []
            let result = HoverPopupAXRead.read(prepare: { true }, copy: {
                copies += 1
                $0 = [] as CFArray
                return error
            }, expired: { XCTFail("AX error remains primary"); return false }, report: { reports.append($0) })
            XCTAssertNil(result)
            XCTAssertEqual(copies, 1)
            XCTAssertEqual(reports, [.copyFailed(error.rawValue)])
        }
    }

    func testPrepareFailureDoesNotSendAXRequest() {
        var reports: [HoverPopupAXRead.Failure] = []
        let result = HoverPopupAXRead.read(prepare: { false }, copy: { _ in
            XCTFail("No AX request after failed preparation"); return .success
        }, expired: { XCTFail("Preparation already failed"); return true }, report: { reports.append($0) })
        XCTAssertNil(result)
        XCTAssertEqual(reports, [.prepareFailed])
    }

    func testLateSuccessIsDiscardedWithoutRetry() {
        var copies = 0
        var reports: [HoverPopupAXRead.Failure] = []
        let result = HoverPopupAXRead.read(prepare: { true }, copy: {
            copies += 1
            $0 = [] as CFArray
            return .success
        }, expired: { true }, report: { reports.append($0) })
        XCTAssertNil(result)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(reports, [.deadlineExpired])
    }

    func testSuccessfulEmptyWindowListRemainsDifferentFromReadFailure() throws {
        let result = HoverPopupAXRead.read(prepare: { true }, copy: {
            $0 = [] as CFArray
            return .success
        }, expired: { false }, report: { _ in XCTFail("Successful reads stay silent") })
        let windows = try XCTUnwrap(result as? [AXUIElement])
        XCTAssertTrue(windows.isEmpty)
    }
}
