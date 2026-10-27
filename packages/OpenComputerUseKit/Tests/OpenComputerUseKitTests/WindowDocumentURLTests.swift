import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class WindowDocumentURLTests: XCTestCase {
    func testWindowIdentityUsesDocumentAttributeWithoutOpeningAnyUI() {
        var reads: [String] = []
        let url = "file:///Users/fixture/Documents/report.numbers"
        let result = formattedURLSegment(role: "AXWindow", title: "report", label: nil) { attribute in
            reads.append(attribute)
            return attribute == kAXDocumentAttribute ? url : "wrong"
        }
        XCTAssertEqual(result, ", URL: \(url)")
        XCTAssertEqual(reads, [kAXDocumentAttribute])
    }

    func testWebURLBehaviorUnchangedAndOtherRolesDoNotReadDocument() {
        XCTAssertEqual(formattedURLSegment(role: "AXWebArea", title: nil, label: nil) {
            XCTAssertEqual($0, kAXURLAttribute)
            return "https://example.com/"
        }, ", URL: https://example.com/")
        for role in [nil, "AXTextField", "AXSheet", "AXGroup"] {
            XCTAssertEqual(formattedURLSegment(role: role, title: nil, label: nil) { _ in
                XCTFail("Do not probe document attributes on unrelated roles")
                return "unexpected"
            }, "")
        }
    }

    func testMissingDocumentDoesNotGuessFromTitleOrBecomeAnError() {
        for value: String? in [nil, "", "report"] {
            XCTAssertEqual(formattedURLSegment(role: "AXWindow", title: "report", label: nil) { _ in value }, "")
        }
        XCTAssertEqual(
            formattedURLSegment(role: "AXWindow", title: nil, label: "file:///report") { _ in "file:///report" },
            ""
        )
    }
}
