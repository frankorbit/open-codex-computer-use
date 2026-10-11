import ApplicationServices
import Foundation
@testable import OpenComputerUseKit
import XCTest

final class SkyMenuDispatchTests: XCTestCase {
    private enum TestError: Error {
        case receiverChanged
        case unknownDelivery
    }

    func testLookupChangingWindowPreventsBothSubmissionRoutes() {
        for foundItem in [true, false] {
            var receiverMatches = true
            var submissions = 0
            XCTAssertThrowsError(try dispatchSkyMenuKey(
                findMenuItem: { receiverMatches = false; return foundItem ? 1 : nil },
                validateReceiver: { if !receiverMatches { throw TestError.receiverChanged } },
                pressMenuItem: { _ in submissions += 1 },
                postKey: { submissions += 1 },
            ))
            XCTAssertEqual(submissions, 0)
        }
    }

    func testBothRoutesValidateAfterLookupAndSubmitExactlyOnce() throws {
        for foundItem in [true, false] {
            var phases: [String] = []
            try dispatchSkyMenuKey(
                findMenuItem: { phases.append("lookup"); return foundItem ? 1 : nil },
                validateReceiver: { phases.append("validate") },
                pressMenuItem: { _ in phases.append("menu") },
                postKey: { phases.append("key") },
            )
            XCTAssertEqual(phases, ["validate", "lookup", "validate", foundItem ? "menu" : "key"])
        }
    }

    func testInvalidReceiverPreventsLookup() {
        XCTAssertThrowsError(try dispatchSkyMenuKey(
            findMenuItem: { XCTFail("unexpected lookup"); return 1 },
            validateReceiver: { throw TestError.receiverChanged },
            pressMenuItem: { _ in XCTFail("unexpected menu action") },
            postKey: { XCTFail("unexpected key") },
        ))
    }

    func testMenuActionUnknownResultNeverFallsBack() {
        var attempts = 0
        XCTAssertThrowsError(try dispatchSkyMenuKey(
            findMenuItem: { 1 },
            validateReceiver: {},
            pressMenuItem: { _ in attempts += 1; throw TestError.unknownDelivery },
            postKey: { XCTFail("must not replay using keys") },
        ))
        XCTAssertEqual(attempts, 1)
    }

    func testKeyDeliveryUnknownResultNeverRetries() {
        var attempts = 0
        XCTAssertThrowsError(try dispatchSkyMenuKey(
            findMenuItem: { nil as Int? },
            validateReceiver: {},
            pressMenuItem: { _ in XCTFail("unexpected menu action") },
            postKey: { attempts += 1; throw TestError.unknownDelivery },
        ))
        XCTAssertEqual(attempts, 1)
    }

    func testUnknownMenuFieldsNeverMatch() {
        let equivalent = SkyMenuKeyEquivalent(character: "W", modifiers: 0)
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "W", cmdModifiers: nil, enabled: true, equivalent: equivalent))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "W", cmdModifiers: 0, enabled: nil, equivalent: equivalent))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "W", cmdModifiers: nil, enabled: nil, equivalent: equivalent))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: nil, cmdModifiers: 0, enabled: true, equivalent: equivalent))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "W", cmdModifiers: 1, enabled: true, equivalent: equivalent))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "W", cmdModifiers: 0, enabled: false, equivalent: equivalent))
        XCTAssertTrue(skyMenuItemMatches(cmdChar: "w", cmdModifiers: 0, enabled: true, equivalent: equivalent))
    }

    func testUnsupportedMenuFieldsRemainUnknown() throws {
        for result in [AXError.attributeUnsupported, .noValue] {
            let modifiers = try readSkyMenuAttribute("AXMenuItemCmdModifiers", read: { (result, nil) }) as? NSNumber
            let enabled = try readSkyMenuAttribute(kAXEnabledAttribute, read: { (result, nil) }) as? NSNumber
            XCTAssertFalse(skyMenuItemMatches(
                cmdChar: "W", cmdModifiers: modifiers?.intValue, enabled: enabled?.boolValue,
                equivalent: SkyMenuKeyEquivalent(character: "W", modifiers: 0),
            ))
        }
    }

    func testAXQueryFailureStopsDispatchInsteadOfBecomingMissingMenu() {
        for attribute in ["AXMenuItemCmdModifiers", kAXEnabledAttribute, kAXChildrenAttribute, kAXMenuBarAttribute] {
            for result in [AXError.cannotComplete, .invalidUIElement, .failure, .notImplemented] {
                var reads = 0
                XCTAssertThrowsError(try dispatchSkyMenuKey(
                    findMenuItem: { () throws -> Int? in
                        _ = try readSkyMenuAttribute(attribute) { reads += 1; return (result, nil) }
                        return nil
                    },
                    validateReceiver: {},
                    pressMenuItem: { _ in XCTFail("unexpected menu action") },
                    postKey: { XCTFail("query failure must not become keyboard fallback") },
                ))
                XCTAssertEqual(reads, 1)
            }
        }
    }

    func testSuccessfulAttributeReadPreservesValue() throws {
        let value = try readSkyMenuAttribute("AXMenuItemCmdModifiers", read: { (.success, NSNumber(value: 1)) })
        XCTAssertEqual((value as? NSNumber)?.intValue, 1)
    }
}
