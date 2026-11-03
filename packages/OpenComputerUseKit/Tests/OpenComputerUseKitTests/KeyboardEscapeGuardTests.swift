import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class KeyboardEscapeGuardTests: XCTestCase {
    func testOnlyUnmodifiedEscapeUsesGuard() throws {
        for key in ["Esc", "Escape", "escape", "ESC"] {
            XCTAssertTrue(try KeyboardEscapeGuard.isPlainEscape(key))
        }
        for key in ["Return", "super+s", "shift+Escape", "alt+Esc", "control+Escape"] {
            XCTAssertFalse(try KeyboardEscapeGuard.isPlainEscape(key))
        }
        XCTAssertThrowsError(try KeyboardEscapeGuard.isPlainEscape("unsupported-key"))
    }

    func testOnlyLiveMenuRolesAreAccepted() throws {
        for role in [kAXMenuRole as String, kAXMenuItemRole as String] {
            XCTAssertNoThrow(try KeyboardEscapeGuard.validateFocusedRole(role))
        }
        let otherRoles: [String?] = [nil, kAXTextAreaRole as String, kAXTextFieldRole as String,
                                     kAXTableRole as String, kAXMenuBarItemRole as String]
        for role in otherRoles {
            XCTAssertThrowsError(try KeyboardEscapeGuard.validateFocusedRole(role)) { error in
                XCTAssertTrue(String(describing: error).contains("AX_INPUT_PREFLIGHT"))
            }
        }
    }

    func testMenuEvidenceIncludesSelectedBarButNotAnOrdinaryBar() {
        for record in [
            escapeTestRecord(1, role: kAXMenuRole as String),
            escapeTestRecord(1, role: kAXMenuItemRole as String),
            escapeTestRecord(1, role: kAXMenuBarItemRole as String, selection: .init(selected: true as NSNumber)),
            escapeTestRecord(1, role: kAXMenuBarItemRole as String,
                             selection: TargetedSelectionState(selected: false as NSNumber)
                                 .includingParentMembership(true))
        ] {
            XCTAssertTrue(KeyboardEscapeGuard.hasObservedMenu(escapeTestSnapshot(records: [record])))
        }
        XCTAssertFalse(KeyboardEscapeGuard.hasObservedMenu(escapeTestSnapshot(records: [])))
        XCTAssertFalse(KeyboardEscapeGuard.hasObservedMenu(escapeTestSnapshot(records: [
            escapeTestRecord(1, role: kAXMenuBarItemRole as String),
            escapeTestRecord(2, role: kAXMenuBarItemRole as String, selection: .init(selected: false as NSNumber)),
            escapeTestRecord(3, role: kAXTextAreaRole as String)
        ])))
    }

    func testLiveReaderChecksFocusOwnershipAndRoleWithoutInput() throws {
        let snapshot = escapeTestSnapshot(records: [escapeTestRecord(1, role: kAXMenuRole as String)])
        for scenario in ["menu", "editor", "foreign-owner", "permission", "timeout", "cancelled", "missing-focus"] {
            var reads = 0
            var restores = 0
            var clock = 0.0
            let reader = KeyboardReceiverAXReader(now: { clock }, checkCancellation: {
                if scenario == "cancelled" { throw CancellationError() }
            }, setTimeout: { _, timeout in
                if timeout == 0 { restores += 1 }
                return .success
            }, copyValue: { _, attribute in
                reads += 1
                if scenario == "permission" { return (.apiDisabled, nil) }
                if scenario == "timeout" { clock = 2.1 }
                if scenario == "missing-focus" { return (.noValue, nil) }
                if attribute == kAXFocusedUIElementAttribute {
                    return (.success, AXUIElementCreateApplication(scenario == "foreign-owner" ? 123 : getpid()))
                }
                XCTAssertEqual(attribute, kAXRoleAttribute)
                return (.success, (scenario == "editor" ? kAXTextAreaRole : kAXMenuRole) as CFString)
            })
            if scenario == "menu" {
                XCTAssertNoThrow(try KeyboardEscapeGuard.validate(in: snapshot, reader: reader))
                XCTAssertEqual(reads, 2)
            } else {
                XCTAssertThrowsError(try KeyboardEscapeGuard.validate(in: snapshot, reader: reader))
            }
            XCTAssertEqual(restores, reads, scenario)
            XCTAssertLessThanOrEqual(reads, 2, scenario)
        }
    }

    func testNoMenuPerformsNoLiveAXQueries() throws {
        let reader = KeyboardReceiverAXReader(setTimeout: { _, _ in
            XCTFail("no menu must not change AX timeout")
            return .success
        }, copyValue: { _, _ in
            XCTFail("no menu must not query live focus")
            return (.failure, nil)
        })
        XCTAssertNoThrow(try KeyboardEscapeGuard.validate(in: escapeTestSnapshot(records: []), reader: reader))
    }
}
