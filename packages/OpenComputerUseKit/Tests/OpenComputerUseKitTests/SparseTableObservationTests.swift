import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class SparseTableObservationTests: XCTestCase {
    func testSparseRowsAndColumnsExplainMissingCellsWithoutInventingTargets() {
        let snapshot = tableSnapshot(extraRoles: [])
        for style in [SnapshotTextStyle.fullState, .actionResult] {
            let text = snapshot.renderedText(style: style)
            XCTAssertTrue(text.contains("Sparse table observation:"))
            XCTAssertTrue(text.contains("does not prove cells are absent or still loading"))
            XCTAssertTrue(text.contains("never guess indexes or infer A1 from the first data cell"))
            XCTAssertTrue(text.contains("does not clear errors, timeouts or stop rules"))
            XCTAssertTrue(text.contains("does not authorize replay"))
        }
        XCTAssertEqual(snapshot.elements.count, 3)
    }

    func testCellPresentOrAXOmittedDoesNotAddSparseHint() {
        XCTAssertFalse(tableSnapshot(extraRoles: [kAXCellRole as String]).renderedText.contains("Sparse table"))
        var snapshot = tableSnapshot(extraRoles: [])
        snapshot.observation = SnapshotObservationOptions(includeAX: false, includeScreenshot: true)
        XCTAssertFalse(snapshot.renderedText.contains("Sparse table"))
        XCTAssertTrue(snapshot.renderedText.contains("Accessibility omitted"))
    }

    func testNonTableOrIncompleteStructureIsNotLabeledSparseTable() {
        let roleSets = [[], [kAXTextAreaRole as String], [kAXTableRole as String],
                        [kAXRowRole as String, kAXColumnRole as String]]
        for roles in roleSets {
            let snapshot = escapeTestSnapshot(records: roles.enumerated().map {
                escapeTestRecord($0.offset, role: $0.element)
            })
            XCTAssertFalse(snapshot.renderedText.contains("Sparse table"))
        }
    }

    private func tableSnapshot(extraRoles: [String]) -> AppSnapshot {
        let roles = [kAXTableRole as String, kAXRowRole as String, kAXColumnRole as String] + extraRoles
        return escapeTestSnapshot(records: roles.enumerated().map { escapeTestRecord($0.offset, role: $0.element) })
    }
}
