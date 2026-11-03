import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXMenuBarOpenerValidationTests: XCTestCase {
    // 各失败分支共用同一受测读取路径，不以单独 mock 断言代替身份校验。
    // swiftlint:disable:next cyclomatic_complexity
    func testLiveNativeMembershipEnabledAndSelectedEvidence() throws {
        for scenario in [
            "valid", "owner", "parent", "role", "bar-role", "disabled", "detached", "selected",
            "other-open", "unknown-selection", "permission", "timeout", "cancelled"
        ] {
            let pid = getpid()
            let element = AXUIElementCreateApplication(scenario == "owner" ? -123 : pid)
            let bar = AXUIElementCreateApplication(-12)
            let other = AXUIElementCreateApplication(-13)
            var clock = 0.0
            var reads = 0
            var restores = 0
            let reader = KeyboardReceiverAXReader(now: { clock }, checkCancellation: {
                if scenario == "cancelled" { throw CancellationError() }
            }, setTimeout: { _, timeout in
                if timeout == 0 { restores += 1 }
                return .success
            }, copyValue: { source, attribute in
                reads += 1
                if scenario == "permission" { return (.apiDisabled, nil) }
                if scenario == "timeout" { clock = 3 }
                switch attribute {
                case kAXMenuBarAttribute: return (.success, bar)
                case kAXParentAttribute: return (.success, scenario == "parent" ? other : bar)
                case kAXRoleAttribute:
                    let barRole = scenario == "bar-role" ? "AXWebArea" : "AXMenuBar"
                    let itemRole = scenario == "role" ? "AXMenuItem" : "AXMenuBarItem"
                    let role = CFEqual(source, bar) ? barRole : itemRole
                    return (.success, role as CFString)
                case kAXEnabledAttribute: return (.success, NSNumber(value: scenario != "disabled"))
                case kAXChildrenAttribute: return (.success, (scenario == "detached" ? [] : [element]) as CFArray)
                case kAXSelectedChildrenAttribute:
                    if scenario == "unknown-selection" { return (.attributeUnsupported, nil) }
                    return (.success, (scenario == "other-open" ? [other] : []) as CFArray)
                case kAXSelectedAttribute: return (.success, NSNumber(value: scenario == "selected"))
                default: XCTFail("unexpected attribute"); return (.attributeUnsupported, nil)
                }
            })
            if scenario == "valid" {
                XCTAssertNoThrow(try AXMenuBarFocus.validateOpener(element, pid: pid, reader: reader))
            } else {
                XCTAssertThrowsError(try AXMenuBarFocus.validateOpener(element, pid: pid, reader: reader), scenario)
            }
            XCTAssertEqual(reads, restores, scenario)
        }
    }
}
