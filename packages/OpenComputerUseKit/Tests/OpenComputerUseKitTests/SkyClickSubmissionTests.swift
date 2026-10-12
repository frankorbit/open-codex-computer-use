import Foundation
@testable import OpenComputerUseKit
import XCTest

final class SkyClickSubmissionTests: XCTestCase {
    func testDefaultPathPreservesLeftRightAndDoubleClickEventsAndDelays() throws {
        for (button, count) in [(MouseButtonKind.left, 1), (.left, 2), (.right, 1)] {
            let recipe = try skyClickEventRecipe(clickCount: count, button: button)
            var posted: [SkyClickEventStep] = []
            var waits: [TimeInterval] = []
            try dispatchSkyClickEvents(recipe, post: { posted.append($0) }, wait: { waits.append($0) })
            XCTAssertEqual(posted, recipe)
            XCTAssertEqual(waits, recipe.map(\.delayAfter))
        }
    }

    func testInvalidAfterPreparationPostsNoMouseEvent() throws {
        var posted: [SkyClickEventStep] = []
        XCTAssertThrowsError(try dispatchSkyClickEvents(
            skyClickEventRecipe(clickCount: 1),
            validateBeforeSubmission: { throw ComputerUseError.message("expired during focus settle") },
            post: { posted.append($0) },
            wait: { _ in XCTFail("No input means no recipe wait") }
        ))
        XCTAssertTrue(posted.isEmpty)
    }

    func testMoveDelayCanRevokePrimerDown() throws {
        var valid = true
        var posted: [SkyClickEventStep] = []
        XCTAssertThrowsError(try dispatchSkyClickEvents(
            skyClickEventRecipe(clickCount: 1),
            validateBeforeSubmission: {
                if !valid { throw ComputerUseError.message("receiver changed") }
            },
            post: { posted.append($0) },
            wait: { _ in valid = false }
        ))
        XCTAssertEqual(posted.map(\.kind), [.moved])
    }

    func testInvalidationAfterEitherDownCannotSuppressMatchingUp() throws {
        for invalidatingPoint in [SkyClickPointKind.primer, .target] {
            let recipe = try skyClickEventRecipe(clickCount: 1)
            var valid = true
            var posted: [SkyClickEventStep] = []
            func run() throws {
                try dispatchSkyClickEvents(recipe, validateBeforeSubmission: {
                    if !valid { throw ComputerUseError.message("popup closed after down") }
                }, post: { step in
                    posted.append(step)
                    if step.kind == .down, step.pointKind == invalidatingPoint { valid = false }
                }, wait: { _ in })
            }
            if invalidatingPoint == .primer {
                XCTAssertThrowsError(try run())
                XCTAssertEqual(posted.map(\.kind), [.moved, .down, .up])
            } else {
                XCTAssertNoThrow(try run())
                XCTAssertEqual(posted, recipe)
            }
            XCTAssertEqual(posted.last?.kind, .up)
            XCTAssertEqual(posted.last?.pointKind, invalidatingPoint)
        }
    }

    func testPostFailureIsNotRetriedOrFollowedByAnotherClick() throws {
        var posted: [SkyClickEventStep] = []
        var waits = 0
        XCTAssertThrowsError(try dispatchSkyClickEvents(
            skyClickEventRecipe(clickCount: 1),
            validateBeforeSubmission: {},
            post: { step in
                posted.append(step)
                throw ComputerUseError.message("delivery unknown")
            },
            wait: { _ in waits += 1 }
        ))
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(waits, 0)
    }
}
