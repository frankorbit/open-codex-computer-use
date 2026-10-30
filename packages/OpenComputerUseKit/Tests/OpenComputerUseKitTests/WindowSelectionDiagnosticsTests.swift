import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class WindowSelectionDiagnosticsTests: XCTestCase {
    func testFailuresKeepOriginalCodeAndNeverRepeatRead() {
        for attribute in [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .noValue, .attributeUnsupported] {
                var calls = 0
                var codes: [Int32] = []
                let value = WindowSelectionDiagnostics.read(attribute: attribute, copy: {
                    calls += 1
                    $0 = [] as CFArray
                    return error
                }, report: { name, code, hasValue in
                    XCTAssertEqual(name, attribute)
                    XCTAssertTrue(hasValue)
                    codes.append(code)
                })
                XCTAssertNil(value)
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(codes, [error.rawValue])
            }
        }
    }

    func testEmptyWindowListIsSuccessAndKeepsOriginalValue() throws {
        let expected = [] as CFArray
        var calls = 0
        let value = WindowSelectionDiagnostics.read(attribute: kAXWindowsAttribute, copy: {
            calls += 1
            $0 = expected
            return .success
        }, report: { _, _, _ in XCTFail("合法空列表不是读取失败") })
        XCTAssertTrue(try XCTUnwrap(value) === expected)
        XCTAssertEqual(calls, 1)
    }

    func testSuccessWithoutValueIsDiagnosedWithoutInventingAXError() {
        var reports = 0
        let value = WindowSelectionDiagnostics.read(attribute: kAXFocusedWindowAttribute, copy: { _ in .success },
                                                    report: { _, code, hasValue in
                                                        reports += 1
                                                        XCTAssertEqual(code, AXError.success.rawValue)
                                                        XCTAssertFalse(hasValue)
                                                    })
        XCTAssertNil(value)
        XCTAssertEqual(reports, 1)
    }

    func testUnrelatedAttributeFailureRemainsSilentAndStillReadsOnce() {
        var calls = 0
        XCTAssertNil(WindowSelectionDiagnostics.read(attribute: "private attribute", copy: { _ in
            calls += 1
            return .cannotComplete
        }, report: { _, _, _ in XCTFail("白名单外属性不可写入日志") }))
        XCTAssertEqual(calls, 1)
    }
}
