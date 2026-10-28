import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXFocusedRowPathTests: XCTestCase {
    private final class Node {
        let role: String
        var pid: pid_t? = 42
        weak var parent: Node?
        var selected = false

        init(_ role: String, parent: Node? = nil) {
            self.role = role
            self.parent = parent
        }
    }

    private func path(_ focus: Node?, root: Node, depth: Int = 64) -> [Node] {
        focusedAncestorPath(focused: focus, root: root, pid: 42, maximumDepth: depth,
                            reader: AXFocusedPathReader(owner: { $0.pid }, parent: { $0.parent }, equal: { $0 === $1 }))
    }

    private func summarized(_ node: Node, path: [Node]) -> Bool {
        shouldSummarizeAXRow(role: node.role, selected: node.selected, element: node,
                             focusedPath: path, equal: { $0 === $1 })
    }

    func testEditingUnselectedReminderKeepsItsRowButSummarizesOtherRows() {
        let root = Node(kAXWindowRole)
        let row = Node(kAXRowRole, parent: root)
        let cell = Node(kAXCellRole, parent: row)
        let title = Node(kAXTextFieldRole, parent: cell)
        let otherRow = Node(kAXRowRole, parent: root)
        let focusedPath = path(title, root: root)
        XCTAssertFalse(row.selected)
        XCTAssertFalse(summarized(row, path: focusedPath))
        XCTAssertTrue(summarized(otherRow, path: focusedPath))
        XCTAssertFalse(summarized(title, path: focusedPath))
        XCTAssertEqual(focusedPath.count, 4)
    }

    func testNestedFocusedRowsRemainTraversable() {
        let root = Node(kAXWindowRole)
        let outer = Node(kAXRowRole, parent: root)
        let inner = Node(kAXRowRole, parent: outer)
        let field = Node(kAXTextFieldRole, parent: inner)
        let focusedPath = path(field, root: root)
        XCTAssertFalse(summarized(outer, path: focusedPath))
        XCTAssertFalse(summarized(inner, path: focusedPath))
    }

    func testSelectedRowsKeepExistingBehaviorWithoutFocus() {
        let row = Node(kAXRowRole)
        row.selected = true
        XCTAssertFalse(summarized(row, path: []))
        row.selected = false
        XCTAssertTrue(summarized(row, path: []))
        XCTAssertFalse(summarized(Node(kAXGroupRole), path: []))
    }

    func testOtherWindowFocusCannotExpandBoundWindowRows() {
        let root = Node(kAXWindowRole)
        let otherRoot = Node(kAXWindowRole)
        let row = Node(kAXRowRole, parent: otherRoot)
        let field = Node(kAXTextFieldRole, parent: row)
        XCTAssertTrue(path(field, root: root).isEmpty)
        XCTAssertTrue(summarized(row, path: path(field, root: root)))
    }

    func testForeignOrUnreadableOwnerInvalidatesEntirePath() {
        let root = Node(kAXWindowRole)
        let row = Node(kAXRowRole, parent: root)
        let field = Node(kAXTextFieldRole, parent: row)
        for owner: pid_t? in [43, nil] {
            row.pid = owner
            XCTAssertTrue(path(field, root: root).isEmpty)
        }
        row.pid = 42
        root.pid = 43
        XCTAssertTrue(path(field, root: root).isEmpty)
    }

    func testCyclesAndDetachedFocusDoNotRetainPartialAncestors() {
        let root = Node(kAXWindowRole)
        let row = Node(kAXRowRole)
        let field = Node(kAXTextFieldRole, parent: row)
        XCTAssertTrue(path(field, root: root).isEmpty)
        row.parent = field
        XCTAssertTrue(path(field, root: root).isEmpty)
        field.parent = field
        XCTAssertTrue(path(field, root: root).isEmpty)
        XCTAssertTrue(path(nil, root: root).isEmpty)
    }

    func testDepthBoundaryIsBoundedAndNeverPublishesPartialPath() {
        let root = Node(kAXWindowRole)
        let row = Node(kAXRowRole, parent: root)
        let field = Node(kAXTextFieldRole, parent: row)
        XCTAssertTrue(path(field, root: root, depth: 0).isEmpty)
        XCTAssertTrue(path(field, root: root, depth: 2).isEmpty)
        XCTAssertEqual(path(field, root: root, depth: 3).count, 3)
        var reads = 0
        let result = focusedAncestorPath(focused: field, root: root, pid: 42, maximumDepth: 2,
                                         reader: AXFocusedPathReader(owner: { $0.pid }, parent: { node in
                                             reads += 1
                                             return node.parent
                                         }, equal: { $0 === $1 }))
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(reads, 2)
    }

    func testFocusChangeDoesNotReusePreviousRows() {
        let root = Node(kAXWindowRole)
        let first = Node(kAXRowRole, parent: root)
        let second = Node(kAXRowRole, parent: root)
        let field = Node(kAXTextFieldRole, parent: first)
        XCTAssertFalse(summarized(first, path: path(field, root: root)))
        field.parent = second
        let next = path(field, root: root)
        XCTAssertTrue(summarized(first, path: next))
        XCTAssertFalse(summarized(second, path: next))
    }
}
