import AppKit
@testable import OpenComputerUseKit
import XCTest

final class SkyClickMenuFocusTests: XCTestCase {
    private final class Harness {
        var now: TimeInterval = 0
        var front: pid_t? = 99
        var identity: Date? = Date(timeIntervalSince1970: 1)
        var rootExists = true
        var popups: Set<CGWindowID> = []
        var begins = 0
        var keys = 0
        var ends = 0
        var waits = 0
        var keyReadyAt: TimeInterval = 0
        var onWait: (() -> Void)?
        var actions: [@Sendable () -> Void] = []
        var endFails = false

        var backend: SkyClickMenuFocusBackend {
            SkyClickMenuFocusBackend(
                now: { self.now }, foregroundPID: { self.front },
                launchDate: { _ in self.identity }, rootExists: { _ in self.rootExists },
                popupIDs: { _ in self.popups },
                begin: { target in
                    self.begins += 1
                    return SkyLightSyntheticFocusContext(deactivateTarget: SkyLightActivationCommand(
                        psn: [], windowID: target.windowID, focused: false
                    ))
                }, makeKey: { _ in
                    self.keys += 1
                    self.keyReadyAt = self.now + 0.080
                },
                end: { _ in
                    self.ends += 1
                    if self.endFails { throw ComputerUseError.message("test cleanup failure") }
                }, wait: { self.waits += 1; self.now += $0; self.onWait?() },
                schedule: { _, action in self.actions.append(action) }
            )
        }

        func tick() {
            let pending = actions
            actions = []
            for action in pending {
                action()
            }
        }
    }

    private func target(_ id: CGWindowID = 10) -> SkyClickTarget {
        SkyClickTarget(
            screenPoint: CGPoint(x: 5, y: 5),
            windowPoint: CGPoint(x: 5, y: 5),
            windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            windowID: id,
            pid: 1
        )
    }

    private func open(_ focus: SkyClickMenuFocus, _ harness: Harness) throws {
        try focus.beginRequest(app: "test")
        try focus.deliver(target: target(), profile: .standard, button: .left, clickCount: 1) {
            harness.popups = [20]
        }
    }

    func testBackgroundSingleClickWaitsForKeyPreparationBeforeInput() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        defer { focus.cancelAfterFailure() }
        var submissions = 0
        try focus.deliver(target: target(), profile: .standard, button: .left, clickCount: 1) {
            XCTAssertEqual(harness.keys, 1)
            XCTAssertGreaterThanOrEqual(harness.now, harness.keyReadyAt)
            submissions += 1
            harness.popups = [20]
        }
        XCTAssertEqual(submissions, 1)
        let waits = harness.waits
        try focus.beginRequest(app: nil)
        XCTAssertEqual(harness.waits, waits, "只读请求不能重复等待 key")
        try focus.deliver(target: target(20), profile: .popup, button: .left, clickCount: 1) {
            XCTAssertEqual(harness.waits, waits, "弹层续点不能重新准备主窗口焦点")
        }
    }

    func testTargetChangeDuringKeyWaitRejectsInputAndAvoidsReusedPIDCleanup() throws {
        for reusedPID in [false, true] {
            let harness = Harness()
            let focus = SkyClickMenuFocus(backend: harness.backend)
            harness.onWait = { [weak harness] in
                if reusedPID { harness?.identity = Date(timeIntervalSince1970: 2) } else { harness?.rootExists = false }
            }
            XCTAssertThrowsError(try focus.deliver(
                target: target(), profile: .standard, button: .left, clickCount: 1
            ) { XCTFail("准备期间目标改变不能投递鼠标事件") })
            XCTAssertEqual(harness.ends, reusedPID ? 0 : 1)
        }
    }

    func testKeySettleDoesNotChangeDoubleClickRightClickOrForegroundTiming() throws {
        for (button, count, foreground) in [(MouseButtonKind.left, 2, false), (.right, 1, false), (.left, 1, true)] {
            let harness = Harness()
            if foreground { harness.front = 1 }
            let focus = SkyClickMenuFocus(backend: harness.backend)
            try focus.deliver(target: target(), profile: .standard, button: button, clickCount: count) {
                XCTAssertEqual(harness.waits, 0, "其他输入不能增加单击 key 准备等待")
            }
            try focus.cancel()
        }
    }

    func testObservationKeepsLeaseAndPopupClickReusesFocusWithoutRekeyingRoot() throws {
        let harness = Harness()
        let manager = SkyClickMenuFocus(backend: harness.backend)
        defer { manager.cancelAfterFailure() }
        try open(manager, harness)
        XCTAssertEqual(harness.ends, 0)
        let waits = harness.waits
        try manager.beginRequest(app: "test")
        XCTAssertEqual(harness.waits, waits)
        harness.now = 10
        harness.tick()
        try manager.deliver(target: target(20), profile: .popup, button: .left, clickCount: 1) {
            harness.popups = [21]
        }
        XCTAssertEqual(harness.begins, 1)
        XCTAssertEqual(harness.keys, 1)
        XCTAssertEqual(harness.ends, 0)
        harness.now = 31
        harness.tick()
        XCTAssertEqual(harness.ends, 0, "旧 timer 不能清除后续交互")
        harness.now = 41
        harness.tick()
        XCTAssertEqual(harness.ends, 1)
    }

    func testClosedPopupChangedRootAppAndTimeoutReleaseExactlyOnce() throws {
        for reason in 0 ..< 4 {
            let harness = Harness()
            let focus = SkyClickMenuFocus(backend: harness.backend)
            try open(focus, harness)
            switch reason {
            case 0: harness.popups = []
            case 1: harness.rootExists = false
            case 2: try focus.beginRequest(app: "other")
            default: harness.now = 31
            }
            harness.tick()
            try focus.cancel()
            XCTAssertEqual(harness.ends, 1)
        }
    }

    func testUserActivationAndPIDReuseNeverDeactivateNewOwner() throws {
        for activate in [true, false] {
            let harness = Harness()
            let focus = SkyClickMenuFocus(backend: harness.backend)
            try open(focus, harness)
            if activate { harness.front = 1 } else { harness.identity = Date(timeIntervalSince1970: 2) }
            harness.tick()
            try focus.cancel()
            XCTAssertEqual(harness.ends, 0)
        }
    }

    func testAnotherSessionReleasesOldLeaseBeforeSubmittingAndOldTimerCannotEndNewLease() throws {
        let harness = Harness()
        let old = SkyClickMenuFocus(backend: harness.backend), new = SkyClickMenuFocus(backend: harness.backend)
        defer { old.cancelAfterFailure(); new.cancelAfterFailure() }
        try open(old, harness)
        try new.deliver(target: target(), profile: .standard, button: .left, clickCount: 1) {
            XCTAssertEqual(harness.ends, 1)
            harness.popups = [21]
        }
        harness.tick()
        try old.cancel()
        XCTAssertEqual(harness.ends, 1)
        try new.cancel()
        XCTAssertEqual(harness.ends, 2)
    }

    func testNoPopupDoesNotLeaveFocusAndFailureNeverReplaysInput() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        var submissions = 0
        try focus.deliver(target: target(), profile: .standard, button: .left, clickCount: 1) {
            submissions += 1
        }
        XCTAssertEqual(harness.ends, 1)
        XCTAssertTrue(harness.actions.isEmpty)
        XCTAssertThrowsError(try focus.deliver(
            target: target(),
            profile: .standard,
            button: .left,
            clickCount: 1
        ) {
            submissions += 1
            throw ComputerUseError.message("unknown delivery")
        })
        XCTAssertEqual(submissions, 2)
        XCTAssertEqual(harness.ends, 2)
    }

    func testCleanupFailureIsReportedAndNeverRepeated() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        try open(focus, harness)
        harness.endFails = true
        XCTAssertThrowsError(try focus.cancel())
        XCTAssertNoThrow(try focus.cancel())
        XCTAssertEqual(harness.ends, 1)
    }

    func testForegroundInputDoesNotSynthesizeFocus() throws {
        let harness = Harness()
        harness.front = 1
        let focus = SkyClickMenuFocus(backend: harness.backend)
        var submissions = 0
        try focus.deliver(target: target(), profile: .standard, button: .left, clickCount: 1) {
            submissions += 1
        }
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(harness.begins + harness.keys + harness.ends, 0)
        XCTAssertTrue(harness.actions.isEmpty)
    }

    func testDirectServiceCallNeverRetainsFocusAcrossRequests() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend, retainsMenus: false)
        try open(focus, harness)
        XCTAssertEqual(harness.ends, 1)
        XCTAssertTrue(harness.actions.isEmpty)
    }

    func testOtherInputFinishesLeaseAndOldTimerCannotCleanUpAgain() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        try open(focus, harness)
        let result = try focus.withInteraction {
            XCTAssertEqual(harness.ends, 0, "不能在动作开始前清除同会话的菜单")
            harness.popups = []
            return "completed"
        }
        XCTAssertEqual(result, "completed")
        XCTAssertEqual(harness.ends, 1)
        harness.tick()
        XCTAssertEqual(harness.ends, 1)
    }
}

extension SkyClickMenuFocusTests {
    func testListAppsDoesNotClearMenuOrChangeItsBoundApp() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        let dispatcher = ComputerUseToolDispatcher(service: ComputerUseService(), menuFocus: focus)
        try open(focus, harness)
        let waits = harness.waits
        XCTAssertFalse(try dispatcher.callTool(name: "list_apps", arguments: [:]).isError)
        XCTAssertThrowsError(try dispatcher.callTool(name: "list_apps", arguments: ["unexpected": true]))
        try focus.beginRequest(app: "test")
        XCTAssertEqual(harness.ends, 0)
        XCTAssertEqual(harness.waits, waits)
        try focus.deliver(target: target(20), profile: .popup, button: .left, clickCount: 1) {
            XCTAssertEqual(harness.begins, 1, "列应用后仍能复用原菜单焦点")
        }
        try focus.cancel()
    }

    func testListAppsInAnotherSessionDoesNotStealMenuOwnership() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        defer { focus.cancelAfterFailure() }
        try open(focus, harness)
        let other = ComputerUseToolDispatcher(
            service: ComputerUseService(), menuFocus: SkyClickMenuFocus(backend: harness.backend)
        )
        XCTAssertFalse(try other.callTool(name: "list_apps", arguments: [:]).isError)
        XCTAssertEqual(harness.ends, 0)
        harness.tick()
        XCTAssertEqual(harness.ends, 0)
    }

    func testContinuousPopupActionsPreserveReadbackAndOriginalExpiry() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        try open(focus, harness)
        let waits = harness.waits
        var submitted = 0
        for time in [10.0, 20.0] {
            harness.now = time
            let observed = try focus.withInteraction {
                submitted += 1
                XCTAssertEqual(harness.ends, 0)
                return harness.popups
            }
            XCTAssertEqual(observed, [20])
            XCTAssertEqual(harness.ends, 0, "动作回读后不能把仍存活的菜单关闭")
            XCTAssertEqual(harness.waits, waits, "连续动作不增加轮询或准备等待")
            harness.tick()
            XCTAssertEqual(harness.ends, 0, "旧代际 timer 不能清除续接状态")
        }
        XCTAssertEqual(submitted, 2)
        harness.now = 31
        harness.tick()
        XCTAssertEqual(harness.ends, 1, "滚动或设置值不能延长原 30 秒租期")
    }

    func testPopupReplacementTransfersLeaseButPreexistingUnrelatedWindowDoesNot() throws {
        for replace in [false, true] {
            let harness = Harness()
            let focus = SkyClickMenuFocus(backend: harness.backend)
            try open(focus, harness)
            harness.popups.insert(99)
            try focus.withInteraction {
                harness.popups = replace ? [21, 99] : [99]
            }
            XCTAssertEqual(harness.ends, replace ? 0 : 1)
            if replace {
                harness.tick()
                XCTAssertEqual(harness.ends, 0)
                try focus.deliver(target: target(21), profile: .popup, button: .left, clickCount: 1) {
                    XCTAssertEqual(harness.begins, 1, "新弹层必须继承而非重建焦点")
                }
            }
            try focus.cancel()
            XCTAssertEqual(harness.ends, 1)
        }
    }

    func testContinuousActionFailureCleansUpWithoutReplay() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        try open(focus, harness)
        var submissions = 0
        XCTAssertThrowsError(try focus.withInteraction {
            submissions += 1
            throw ComputerUseError.message("unknown input effect")
        })
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(harness.ends, 1)
        harness.tick()
        XCTAssertEqual(harness.ends, 1)
    }

    func testContinuousActionStillCleansUpChangedTargetAndExpiredLease() throws {
        for reason in 0 ..< 4 {
            let harness = Harness()
            let focus = SkyClickMenuFocus(backend: harness.backend)
            try open(focus, harness)
            try focus.withInteraction {
                switch reason {
                case 0: harness.rootExists = false
                case 1: harness.identity = Date(timeIntervalSince1970: 2)
                case 2: harness.front = 1
                default: harness.now = 31
                }
            }
            XCTAssertEqual(harness.ends, reason == 1 || reason == 2 ? 0 : 1)
            harness.tick()
            XCTAssertEqual(harness.ends, reason == 1 || reason == 2 ? 0 : 1)
        }
    }

    func testOrdinaryActionWithoutLeaseDoesNotPrepareOrWaitForMenuFocus() throws {
        let harness = Harness()
        let focus = SkyClickMenuFocus(backend: harness.backend)
        XCTAssertEqual(try focus.withInteraction { "ok" }, "ok")
        XCTAssertEqual(harness.begins + harness.keys + harness.ends + harness.waits, 0)
        XCTAssertTrue(harness.actions.isEmpty)
    }

    func testFailedOwnershipTransferDoesNotSubmitNewInput() throws {
        let harness = Harness()
        let old = SkyClickMenuFocus(backend: harness.backend)
        let new = SkyClickMenuFocus(backend: harness.backend)
        try open(old, harness)
        harness.endFails = true
        XCTAssertThrowsError(try new.deliver(target: target(), profile: .standard, button: .left, clickCount: 1) {
            XCTFail("前一个交互清理失败时不能提交下一次点击")
        })
        XCTAssertEqual(harness.ends, 1)
        harness.tick()
        XCTAssertEqual(harness.ends, 1)
    }
}
