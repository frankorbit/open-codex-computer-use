import XCTest
@testable import OpenComputerUseKit

/// Pure record-filter tests for the targeted lookup. The native AX search and
/// window resolution need separate live desktop validation; the
/// criteria matching is pure string logic and verified here.
final class TargetedAXTests: XCTestCase {
    private func criteria(
        text: String? = nil,
        exact: Bool = false,
        role: String? = nil
    ) -> TargetedAX.Criteria {
        TargetedAX.Criteria(text: text, exact: exact, role: role, limit: 20, maxNodes: 500)
    }

    func testRoleEqualsToleratesAXPrefix() {
        XCTAssertTrue(targetedRoleEquals("AXButton", "button"))
        XCTAssertTrue(targetedRoleEquals("AXButton", "AXButton"))
        XCTAssertTrue(targetedRoleEquals("button", "AXButton"))
        XCTAssertFalse(targetedRoleEquals("AXButton", "textfield"))
        XCTAssertFalse(targetedRoleEquals(nil, "button"))
    }

    func testRoleMatchIgnoresWordSeparatorsFromTheRenderedTree() {
        // 快照树把角色渲染成带空格的词（text field、pop up button），照抄过来查询也必须命中。
        for wanted in ["text field", "text_field", "text-field", "Text Field", "AXTextField", "textfield", " AX text field "] {
            XCTAssertTrue(targetedRoleEquals("AXTextField", wanted), wanted)
        }
        XCTAssertTrue(targetedRoleEquals("AXPopUpButton", "pop up button"))
        XCTAssertTrue(targetedRoleEquals("AXMenuButton", "menu_button"))
        XCTAssertTrue(targetedRoleEquals("AXStaticText", "static-text"))
        // 分隔符只被忽略，不会让不同角色相等。
        XCTAssertFalse(targetedRoleEquals("AXTextField", "text area"))
        XCTAssertFalse(targetedRoleEquals("AXPopUpButton", "button"))
        XCTAssertFalse(targetedRoleEquals("AXTextField", " "))
    }

    func testTextMatchesTitleDescriptionOrValueSubstring() {
        let c = criteria(text: "compose")
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "Compose", description: nil, value: nil))
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: nil, description: "Compose a message", value: nil))
        XCTAssertTrue(targetedRecordMatches(c, role: "AXTextField", title: nil, description: nil, value: "re: compose"))
        XCTAssertFalse(targetedRecordMatches(c, role: "AXButton", title: "Send", description: nil, value: "hi"))
    }

    func testExactRequiresFullMatch() {
        let c = criteria(text: "Compose", exact: true)
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "compose", description: nil, value: nil))
        XCTAssertFalse(targetedRecordMatches(c, role: "AXButton", title: "Compose mail", description: nil, value: nil))
    }

    func testRoleFilterCombinesWithText() {
        let c = criteria(text: "send", role: "button")
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "Send", description: nil, value: nil))
        // right text, wrong role
        XCTAssertFalse(targetedRecordMatches(c, role: "AXStaticText", title: "Send", description: nil, value: nil))
    }

    func testRoleOnlyMatchesAnyText() {
        let c = criteria(role: "AXButton")
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "anything", description: nil, value: nil))
        XCTAssertFalse(targetedRecordMatches(c, role: "AXTextField", title: "anything", description: nil, value: nil))
    }
}
