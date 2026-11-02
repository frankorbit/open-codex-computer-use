import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class TargetedSelectionStateTests: XCTestCase {
    func testSelectedMenuItemRetainsNativeSelectionAndMarkInQueryOutput() {
        let result = output(selected: kCFBooleanTrue, mark: "✓" as NSString)
        XCTAssertEqual(result["selected"] as? Bool, true)
        XCTAssertEqual(result["mark_character"] as? String, "✓")
        XCTAssertEqual(result["title"] as? String, "Every Week")
        XCTAssertEqual(result["index"] as? Int, 1_000_001)
    }

    func testExplicitFalseAndEmptyMarkArePreservedWithoutInferringSelection() {
        let result = output(selected: kCFBooleanFalse, mark: "" as NSString)
        XCTAssertEqual(result["selected"] as? Bool, false)
        XCTAssertEqual(result["mark_character"] as? String, "")
        let markOnly = output(selected: nil, mark: "•" as NSString)
        XCTAssertNil(markOnly["selected"])
        XCTAssertEqual(markOnly["mark_character"] as? String, "•")
    }

    func testMissingUnsupportedAndMalformedStatesStayUnknown() {
        var error = AXError.attributeUnsupported
        let unsupported = AXValueCreate(.axError, &error)
        for value: AnyObject? in [nil, NSNull(), unsupported, "true" as NSString, NSNumber(value: 2)] {
            let result = output(selected: value, mark: unsupported)
            XCTAssertNil(result["selected"])
            XCTAssertNil(result["mark_character"])
            XCTAssertEqual(result["role"] as? String, "AXMenuItem")
        }
    }

    func testSelectionMetadataDoesNotChangeActionsOrUnselectedRecordShape() {
        let unknown = output(selected: nil, mark: nil)
        XCTAssertEqual(Set(unknown.keys), ["index", "role", "title", "actions"])
        XCTAssertEqual(unknown["actions"] as? [String], ["Press"])
        let selected = output(selected: kCFBooleanTrue, mark: nil)
        XCTAssertEqual(selected["actions"] as? [String], unknown["actions"] as? [String])
    }

    func testUnexpectedLongMenuMarkIsBounded() {
        let result = output(selected: nil, mark: String(repeating: "✓", count: 1100) as NSString)
        XCTAssertEqual((result["mark_character"] as? String)?.count, 1000)
    }

    private func output(selected: AnyObject?, mark: AnyObject?) -> [String: Any] {
        let record = ElementRecord(
            index: 1_000_001, identifier: nil, element: nil, localFrame: nil,
            role: "AXMenuItem", title: "Every Week", rawActions: [kAXPressAction], prettyActions: ["Press"],
            selectionState: TargetedSelectionState(selected: selected, markCharacter: mark)
        )
        return ComputerUseService().compactRecordDictionary(record)
    }
}
