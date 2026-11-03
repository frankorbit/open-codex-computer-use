import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXSelectionObservationTests: XCTestCase {
    func testParentMembershipAppearsInSnapshotAndQueryWithoutOwnSelectedAttribute() {
        var observer = AXSelectionObservation<Int>(read: { parent, limit, _ in
            XCTAssertEqual(parent, 38)
            XCTAssertEqual(limit, 128)
            return [42]
        })
        let members = observer.selectedChildren(of: 38, role: "AXList")
        let state = TargetedSelectionState().includingParentMembership(members.contains(42))
        let record = record(42, state)
        let text = snapshot([42: record], lines: ["42 container (selected) item.txt"]).renderedText
        XCTAssertTrue(text.contains("Selected:\n\t42 container (selected)"))
        XCTAssertTrue(text.contains("missing selected markers are unknown, not false"))
        let output = ComputerUseService().compactRecordDictionary(record)
        XCTAssertEqual(output["selected"] as? Bool, true)
        XCTAssertEqual(output["selection_sources"] as? [String], ["parent.AXSelectedChildren"])
        XCTAssertEqual(state.traits, ["selected"])
        XCTAssertNil(TargetedSelectionState().includingParentMembership(members.contains(43)).selected)
    }

    func testExplicitFalseConflictingWithParentDoesNotReportSuccessOrUnselected() {
        let state = TargetedSelectionState(selected: kCFBooleanFalse).includingParentMembership(true)
        XCTAssertNil(state.selected)
        XCTAssertEqual(state.traits, ["selection-conflict"])
        XCTAssertNil(state.includingParentMembership(true).selected)
        XCTAssertTrue(state.includingParentMembership(true).selectionConflict)
        let output = ComputerUseService().compactRecordDictionary(record(42, state))
        XCTAssertNil(output["selected"])
        XCTAssertEqual(output["selected_attribute"] as? Bool, false)
        XCTAssertEqual(output["selection_conflict"] as? Bool, true)
        XCTAssertFalse(snapshot([42: record(42, state)], lines: ["42 container (selection-conflict)"])
            .renderedText.contains("Selected:"))
    }

    func testMissingFailedAndEmptyParentReadsRemainUnknown() {
        for value: [Int]? in [nil, []] {
            var observer = AXSelectionObservation<Int>(read: { _, _, _ in value })
            let members = observer.selectedChildren(of: 38, role: "AXList")
            let unknown = TargetedSelectionState().includingParentMembership(members.contains(42))
            XCTAssertNil(unknown.selected)
            XCTAssertFalse(unknown.selectionConflict)
            XCTAssertEqual(
                TargetedSelectionState(selected: kCFBooleanFalse)
                    .includingParentMembership(false).selected,
                false
            )
            XCTAssertEqual(
                TargetedSelectionState(selected: kCFBooleanTrue)
                    .includingParentMembership(false).selected,
                true
            )
        }
    }

    func testContainerAndMemberBudgetsNeverInferUnselectedForOmittedNodes() {
        var reads = 0
        var observer = AXSelectionObservation<Int>(read: { _, _, _ in reads += 1; return Array(0 ..< 1000) })
        for _ in 0 ..< 40 {
            XCTAssertLessThanOrEqual(observer.selectedChildren(of: 0, role: "AXList").count, 128)
        }
        XCTAssertEqual(reads, 32)
        XCTAssertNil(TargetedSelectionState().includingParentMembership(false).selected)
    }

    func testDeadlineAndNonContainersDoNotIssueExtraReads() {
        var time: TimeInterval = 0
        var reads = 0
        var observer = AXSelectionObservation<Int>(
            now: { time },
            read: { _, _, _ in reads += 1; time += 0.16; return [1] }
        )
        for role in [nil, "AXWebArea", "AXMenuItem", "AXTextField", "AXWindow"] {
            XCTAssertTrue(observer.selectedChildren(of: 0, role: role).isEmpty)
        }
        XCTAssertEqual(reads, 0)
        time = 1
        XCTAssertTrue(observer.selectedChildren(of: 0, role: "AXList").isEmpty)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(observer.selectedChildren(of: 0, role: "AXList").isEmpty)
        XCTAssertEqual(reads, 1)
    }

    func testSelectionEvidenceDoesNotLeakIntoNextObservationOrOtherContainer() {
        var first = AXSelectionObservation<Int>(read: { parent, _, _ in parent == 38 ? [42] : [] })
        XCTAssertEqual(first.selectedChildren(of: 38, role: "AXList"), [42])
        XCTAssertTrue(first.selectedChildren(of: 39, role: "AXList").isEmpty)
        var second = AXSelectionObservation<Int>(read: { _, _, _ in [] })
        XCTAssertTrue(second.selectedChildren(of: 38, role: "AXList").isEmpty)
    }

    func testOtherTreeWorkDoesNotSpendAdditionalSelectionReadBudget() {
        var time: TimeInterval = 0
        var observer = AXSelectionObservation<Int>(now: { time }, read: { _, _, _ in [42] })
        time = 1
        XCTAssertEqual(observer.selectedChildren(of: 38, role: "AXList"), [42])
        time = 2
        XCTAssertEqual(observer.selectedChildren(of: 38, role: "AXList"), [42])
    }

    func testScreenshotOnlyObservationDoesNotExposeSelectionSummary() {
        let selected = TargetedSelectionState(selected: kCFBooleanTrue)
        var value = snapshot([42: record(42, selected)], lines: [])
        value.observation = SnapshotObservationOptions(includeAX: false)
        XCTAssertFalse(value.renderedText.contains("Selected:"))
        XCTAssertFalse(value.renderedText.contains("Selection evidence:"))
    }

    func testSummaryUsesOnlyRenderedIndexesAndBoundsLargeSelections() {
        let selected = TargetedSelectionState(selected: kCFBooleanTrue)
        let records = Dictionary(uniqueKeysWithValues: (0 ..< 99).map { ($0, record($0, selected)) })
        let summary = renderedSelectionSummary(records: records)
        XCTAssertEqual(summary.count, 67)
        XCTAssertTrue(summary.last?.contains("35 additional") == true)
        XCTAssertFalse(summary.contains("\t99 container"))
        let large = renderedSelectionSummary(records: [0: ElementRecord(
            index: 0,
            identifier: nil,
            element: nil,
            localFrame: nil,
            rawActions: [],
            prettyActions: [],
            selectionState: selected,
            renderedDescription: String(repeating: "a", count: 9000)
        )])
        XCTAssertTrue(large.last?.contains("truncated") == true)
        let unrendered = ElementRecord(
            index: 100,
            identifier: nil,
            element: nil,
            localFrame: nil,
            rawActions: [],
            prettyActions: [],
            selectionState: selected
        )
        XCTAssertTrue(renderedSelectionSummary(records: [100: unrendered]).isEmpty)
    }

    func testObservedSelectionAfterFailedSetterDoesNotClearErrorOrReplay() {
        var sent = 0
        let state = TargetedSelectionState().includingParentMembership(true)
        XCTAssertThrowsError(try selectNativeListItem(
            containing: 42, opensItem: true,
            reader: AXListSelectionReader<Int>(
                parent: { $0 == 42 ? 38 : nil },
                role: { _ in "AXList" },
                selectionCapability: { _ in (.success, true) }
            ),
            prepare: { _ in }, select: { _, _ in sent += 1; return .attributeUnsupported }
        ))
        let output = snapshot([42: record(42, state)], lines: ["42 container (selected)"]).renderedText
        XCTAssertTrue(output.contains("does not clear input errors or authorize replay"))
        XCTAssertEqual(sent, 1)
    }

    private func record(_ index: Int, _ selection: TargetedSelectionState) -> ElementRecord {
        ElementRecord(
            index: index,
            identifier: nil,
            element: nil,
            localFrame: nil,
            role: "AXGroup",
            rawActions: ["AXOpen"],
            prettyActions: ["Open"],
            selectionState: selection,
            renderedDescription: "\(index) container (selected)"
        )
    }

    private func snapshot(_ records: [Int: ElementRecord], lines: [String]) -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(
                name: "Finder",
                bundleIdentifier: "com.apple.finder",
                pid: 1,
                runningApplication: NSRunningApplication.current
            ),
            windowTitle: "Desktop",
            windowBounds: nil,
            targetWindowID: nil,
            targetWindowLayer: nil,
            screenshotData: nil,
            mode: .accessibility,
            treeLines: lines,
            focusedSummary: nil,
            focusedElement: nil,
            selectedText: nil,
            windowElement: nil,
            elements: records
        )
    }
}
