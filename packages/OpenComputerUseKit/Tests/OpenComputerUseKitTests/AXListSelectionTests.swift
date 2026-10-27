import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXListSelectionTests: XCTestCase {
    final class Node {
        let role: String
        var parent: Node?
        init(_ role: String, parent: Node? = nil) {
            self.role = role
            self.parent = parent
        }
    }

    func testFileNameSelectsImmediateListChildExactlyOnceWithoutOpening() throws {
        let list = Node("AXList")
        let row = Node("AXButton", parent: list)
        let text = Node("AXTextField", parent: row)
        var prepared = 0
        var sent = 0
        let selected = try selectNativeListItem(
            containing: text, opensItem: true,
            reader: .init(parent: { $0.parent }, role: { $0.role },
                          selectionCapability: { _ in (.success, true) }),
            prepare: { XCTAssertTrue($0 === list); prepared += 1 },
            select: { target, child in
                XCTAssertTrue(target === list)
                XCTAssertTrue(child === row)
                sent += 1
                return .success
            }
        )
        XCTAssertTrue(selected)
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(sent, 1)
    }

    func testEveryPostSubmissionFailureThrowsWithoutFallthroughOrReplay() {
        let errors: [AXError] = [.failure, .attributeUnsupported, .actionUnsupported, .cannotComplete,
                                 .noValue, .invalidUIElement, .illegalArgument, .apiDisabled, .notImplemented]
        for error in errors {
            let text = Node("AXTextField", parent: Node("AXList"))
            var sent = 0
            var fellThrough = false
            do {
                let selected = try selectNativeListItem(
                    containing: text, opensItem: true,
                    reader: .init(parent: { $0.parent }, role: { $0.role },
                                  selectionCapability: { _ in (.success, true) }), prepare: { _ in },
                    select: { _, _ in sent += 1; return error }
                )
                fellThrough = !selected
                XCTFail("发送后错误不得返回成功或进入其他动作")
            } catch {
                XCTAssertTrue(String(describing: error).contains("selection was attempted"))
            }
            XCTAssertEqual(sent, 1)
            XCTAssertFalse(fellThrough)
        }
    }

    func testMissingFileSelectionCapabilityFailsBeforeAnyInput() {
        let capabilities: [(AXError, Bool)] = [
            (.success, false), (.attributeUnsupported, false), (.cannotComplete, false), (.apiDisabled, false)
        ]
        for capability in capabilities {
            XCTAssertThrowsError(try selectNativeListItem(
                containing: Node("AXTextField", parent: Node("AXList")), opensItem: true,
                reader: .init(parent: { $0.parent }, role: { $0.role },
                              selectionCapability: { _ in capability }),
                prepare: { _ in XCTFail("未确认能力不得准备输入") },
                select: { _, _ in XCTFail("未确认能力不得发送输入"); return .success }
            ))
        }
    }

    func testOrdinaryNonSelectableListAndNonListRetainOtherRoutesBeforeInput() throws {
        for parent in [Node("AXList"), Node("AXGroup"), Node("AXWebArea", parent: Node("AXList"))] {
            XCTAssertFalse(try selectNativeListItem(
                containing: Node("AXButton", parent: parent), opensItem: false,
                reader: .init(parent: { $0.parent }, role: { $0.role },
                              selectionCapability: { _ in (.success, false) }),
                prepare: { _ in XCTFail("不应准备输入") },
                select: { _, _ in XCTFail("不应发送输入"); return .success }
            ))
        }
    }

    func testUnknownPermissionAndStaleErrorsStopBeforeInputEvenForOrdinaryList() {
        for error: AXError in [.apiDisabled, .cannotComplete, .invalidUIElement] {
            XCTAssertThrowsError(try selectNativeListItem(
                containing: Node("AXButton", parent: Node("AXList")), opensItem: false,
                reader: .init(parent: { $0.parent }, role: { $0.role },
                              selectionCapability: { _ in (error, false) }),
                prepare: { _ in XCTFail("能力查询失败不得准备输入") },
                select: { _, _ in XCTFail("能力查询失败不得发送输入"); return .success }
            ))
        }
    }

    func testCyclicParentTraversalIsBoundedWithoutInput() throws {
        let node = Node("AXGroup")
        node.parent = node
        defer { node.parent = nil }
        var count = 0
        XCTAssertFalse(try selectNativeListItem(
            containing: node, opensItem: true,
            reader: .init(parent: { count += 1; return $0.parent }, role: { $0.role },
                          selectionCapability: { _ in XCTFail("无列表不得查询能力"); return (.success, false) }),
            prepare: { _ in XCTFail("无列表不得准备输入") },
            select: { _, _ in XCTFail("无列表不得输入"); return .success }
        ))
        XCTAssertEqual(count, 8)
    }

    func testNonSelectableInnerListRetainsSelectionOfOuterListRow() throws {
        for unavailable: (AXError, Bool) in [(.success, false), (.attributeUnsupported, false)] {
            let outer = Node("AXList")
            let row = Node("AXRow", parent: outer)
            let inner = Node("AXList", parent: row)
            let button = Node("AXButton", parent: inner)
            var sent = 0
            XCTAssertTrue(try selectNativeListItem(
                containing: button, opensItem: false,
                reader: .init(
                    parent: { $0.parent }, role: { $0.role },
                    selectionCapability: { $0 === outer ? (.success, true) : unavailable }
                ),
                prepare: { XCTAssertTrue($0 === outer) },
                select: { list, selected in
                    XCTAssertTrue(list === outer)
                    XCTAssertTrue(selected === row)
                    sent += 1
                    return .success
                }
            ))
            XCTAssertEqual(sent, 1)
        }
    }
}
