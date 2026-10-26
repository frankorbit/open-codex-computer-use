import AppKit
import XCTest
@testable import OpenComputerUseKit

final class TargetedQuerySafetyTests: XCTestCase {
    func testWindowIDValidationRejectsCrashInputsAndWrongTypes() throws {
        XCTAssertNil(try validatedQueryWindowID(nil))
        XCTAssertEqual(try validatedQueryWindowID(1), 1)
        XCTAssertEqual(try validatedQueryWindowID(UInt32.max), UInt32.max)
        for value: Any in [-1, 0, 1.5, Double.infinity, Double.nan, Double(UInt32.max) + 1, true, "1", NSNull()] {
            XCTAssertThrowsError(try validatedQueryWindowID(value), "\(value)")
        }
        let dispatcher = ComputerUseToolDispatcher()
        let result = dispatcher.callToolAsResult(name: "query", arguments: ["app": "NoSuchReviewApp", "text": "Send", "window_id": -1])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("window_id") == true)
    }

    func testQueryStringsAndExactRejectSilentCoercion() throws {
        XCTAssertEqual(try validatedQueryString("Send", key: "text"), "Send")
        XCTAssertThrowsError(try validatedQueryString(3, key: "text"))
        XCTAssertThrowsError(try validatedQueryString(String(repeating: "x", count: 1001), key: "text"))
        XCTAssertTrue(try validatedQueryExact(true))
        XCTAssertFalse(try validatedQueryExact(nil))
        XCTAssertThrowsError(try validatedQueryExact(1))
        XCTAssertThrowsError(try validatedQueryExact("true"))
    }

    func testRegistryRejectsWrongAppAndRestartedProcess() throws {
        let registry = TargetedElementRegistry<String>()
        let original = TargetedAppIdentity(pid: 1, bundleIdentifier: "com.example.A", launchedAt: Date(timeIntervalSince1970: 1))
        let index = registry.insert(app: original) { _ in "control" }
        XCTAssertEqual(try registry.resolve(index, app: original), "control")
        for identity in [TargetedAppIdentity(pid: 2, bundleIdentifier: "com.example.A", launchedAt: original.launchedAt),
                         TargetedAppIdentity(pid: 1, bundleIdentifier: "com.example.B", launchedAt: original.launchedAt),
                         TargetedAppIdentity(pid: 1, bundleIdentifier: "com.example.A", launchedAt: Date(timeIntervalSince1970: 2))] {
            XCTAssertThrowsError(try registry.resolve(index, app: identity))
        }
        XCTAssertEqual(try registry.resolve(index, app: original), "control")
    }

    func testRegistryEvictsExpiresAndDoesNotReuseClearedIndexes() throws {
        var now = Date(timeIntervalSince1970: 0)
        let app = TargetedAppIdentity(pid: 1, bundleIdentifier: nil, launchedAt: nil)
        let registry = TargetedElementRegistry<Int>(capacity: 2, lifetime: 10, now: { now })
        let first = registry.insert(app: app) { $0 }
        let second = registry.insert(app: app) { $0 }
        let third = registry.insert(app: app) { $0 }
        XCTAssertThrowsError(try registry.resolve(first, app: app))
        XCTAssertEqual(try registry.resolve(second, app: app), second)
        registry.remove(second)
        XCTAssertThrowsError(try registry.resolve(second, app: app))
        now = now.addingTimeInterval(10)
        XCTAssertThrowsError(try registry.resolve(third, app: app))
        registry.clear()
        let fourth = registry.insert(app: app) { $0 }
        XCTAssertGreaterThan(fourth, third)
        XCTAssertThrowsError(try registry.resolve(third, app: app))
    }

    func testReadOnlyResolutionNeverLaunchesAbsentApp() {
        XCTAssertThrowsError(try AppDiscovery.resolveRunning("NoSuchReviewApp", applications: []))
        XCTAssertThrowsError(try AppDiscovery.resolveRunning("com.1password.1password", applications: []))
    }

    func testWideTreeBoundsChildFetchAndReportsPartialMatches() throws {
        var fetched = 0
        let result = try boundedTargetedWalk(root: 0, maxNodes: 3, limit: 10, expired: { false }, inspect: { node in
            (node > 0, node == 0)
        }, children: { _, remaining in
            fetched = remaining
            return (Array(1...remaining), true)
        })
        XCTAssertEqual(fetched, 2)
        XCTAssertEqual(result.visitedNodes, 3)
        XCTAssertEqual(result.matches, [1, 2])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stopReason, "max_nodes")
    }

    func testTraversalDeduplicatesCyclesAndStopsAtResultLimit() throws {
        let cycle = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { _ in (true, true) }, children: { node, _ in
            ([node, (node + 1) % 2], false)
        })
        XCTAssertEqual(cycle.matches, [0, 1])
        XCTAssertFalse(cycle.truncated)
        let limited = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 1, expired: { false }, inspect: { _ in (true, true) }, children: { _, _ in XCTFail("should not fetch children"); return ([], false) })
        XCTAssertEqual(limited.stopReason, "limit")
    }

    func testSlowChildFetchReportsTimeoutRatherThanNodeLimit() throws {
        var expired = false
        let result = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { expired },
                                            inspect: { _ in (true, true) }, children: { _, _ in
            expired = true
            return ([], true)
        })
        XCTAssertEqual(result.matches, [0])
        XCTAssertEqual(result.stopReason, "timeout")
    }

    func testExactDoesNotMatchTruncatedLongLabel() {
        let criteria = TargetedAX.Criteria(text: String(repeating: "x", count: 1000), exact: true, role: nil, limit: 20, maxNodes: 500)
        XCTAssertFalse(targetedRecordMatches(criteria, role: "AXButton", title: String(repeating: "x", count: 1001), description: nil, value: nil))
    }

    func testTraversalReportsTimeoutAndAXErrors() throws {
        let timedOut = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { true }, inspect: { _ in XCTFail("should not inspect"); return (false, true) }, children: { _, _ in ([], false) })
        XCTAssertEqual(timedOut.visitedNodes, 0)
        XCTAssertEqual(timedOut.stopReason, "timeout")
        let failed = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { node in
            if node == 0 { throw ComputerUseError.stateUnavailable("unreadable") }
            return (true, true)
        }, children: { _, _ in XCTFail("should not fetch children of an unreadable root"); return ([1], false) })
        XCTAssertEqual(failed.matches, [])
        XCTAssertEqual(failed.visitedNodes, 1)
        XCTAssertEqual(failed.unreadableNodes, 0)
        XCTAssertEqual(failed.stopReason, "ax_error")
        let rootChildren = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { _ in (true, true) },
                                                  children: { _, _ in throw ComputerUseError.stateUnavailable("unreadable") })
        XCTAssertEqual(rootChildren.matches, [0])
        XCTAssertEqual(rootChildren.stopReason, "ax_error")
    }

    func testUnreadableNodeSkipsOnlyItsSubtree() throws {
        // 0 -> [1, 2]; 1 -> [3]; 2 -> [4]. Node 1 cannot be read, so 3 is never reached; 2 and 4 still are.
        let tree = [0: [1, 2], 1: [3], 2: [4]]
        var fetched: [Int] = []
        let result = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { node in
            if node == 1 { throw ComputerUseError.stateUnavailable("unreadable") }
            return (node != 0, true)
        }, children: { node, _ in
            fetched.append(node)
            return (tree[node] ?? [], false)
        })
        XCTAssertEqual(result.matches, [2, 4])
        XCTAssertEqual(fetched, [0, 2, 4])
        XCTAssertEqual(result.visitedNodes, 4)
        XCTAssertEqual(result.unreadableNodes, 1)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stopReason, "unreadable_nodes")
    }

    func testPopoverSubtreeIsVisibleWithinThePopoverEvenOutsideTheWindow() {
        // 提醒事项实测：主窗口 x 264–1492，详情弹层 x 1477–1823，日期框 x 1692–1790 在主窗口之外。
        let window = CGRect(x: 264, y: 263, width: 1228, height: 692)
        let popover = CGRect(x: 1477, y: 74, width: 346, height: 765)
        let dateField = CGRect(x: 1692.5, y: 269, width: 97.5, height: 24)
        XCTAssertFalse(targetedNodeVisibility(frame: dateField, clip: window, isPopover: false).visible,
                       "without the popover rule the field is clipped away")
        let host = targetedNodeVisibility(frame: popover, clip: window, isPopover: true)
        XCTAssertTrue(host.visible)
        XCTAssertEqual(host.childClip, popover)
        XCTAssertTrue(targetedNodeVisibility(frame: dateField, clip: host.childClip, isPopover: false).visible)
        // 弹层整个在主窗口外也可见；弹层内、但在弹层范围外的元素仍不可见。
        let offWindow = CGRect(x: 1600, y: 74, width: 200, height: 300)
        XCTAssertTrue(targetedNodeVisibility(frame: offWindow, clip: window, isPopover: true).visible)
        XCTAssertFalse(targetedNodeVisibility(frame: CGRect(x: 1900, y: 100, width: 50, height: 20),
                                              clip: popover, isPopover: false).visible)
        // 普通节点继承所在范围；没有位置或空框视为可见；空框的弹层不改范围。
        XCTAssertEqual(targetedNodeVisibility(frame: dateField, clip: popover, isPopover: false).childClip, popover)
        XCTAssertTrue(targetedNodeVisibility(frame: nil, clip: window, isPopover: false).visible)
        XCTAssertTrue(targetedNodeVisibility(frame: .zero, clip: window, isPopover: false).visible)
        XCTAssertEqual(targetedNodeVisibility(frame: .zero, clip: window, isPopover: true).childClip, window)
    }

    func testUnreadableChildListSkipsOnlyThatSubtree() throws {
        let tree = [0: [1, 2], 2: [3]]
        let result = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { node in
            (node == 3, true)
        }, children: { node, _ in
            if node == 1 { throw ComputerUseError.stateUnavailable("children unreadable") }
            return (tree[node] ?? [], false)
        })
        XCTAssertEqual(result.matches, [3])
        XCTAssertEqual(result.unreadableNodes, 1)
        XCTAssertEqual(result.stopReason, "unreadable_nodes")
    }

    func testEarlierStopReasonOutranksSkippedNodes() throws {
        let result = try boundedTargetedWalk(root: 0, maxNodes: 3, limit: 10, expired: { false }, inspect: { node in
            if node == 1 { throw ComputerUseError.stateUnavailable("unreadable") }
            return (true, true)
        }, children: { node, _ in (node == 0 ? [1, 2, 3, 4] : [], false) })
        XCTAssertEqual(result.unreadableNodes, 1)
        XCTAssertEqual(result.stopReason, "max_nodes")
    }

    func testCompleteWalkWithoutSkipsIsNotTruncated() throws {
        let result = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { _ in (false, true) },
                                            children: { node, _ in (node == 0 ? [1] : [], false) })
        XCTAssertEqual(result.unreadableNodes, 0)
        XCTAssertNil(result.stopReason)
        XCTAssertFalse(result.truncated)
    }
}
