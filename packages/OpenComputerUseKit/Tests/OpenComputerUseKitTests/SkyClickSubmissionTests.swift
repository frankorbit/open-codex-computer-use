import Foundation
@testable import OpenComputerUseKit
import XCTest

final class SkyClickSubmissionTests: XCTestCase {
    func testPopupDeliversExactlyOneTargetPairThroughSkyLight() throws {
        let recipe = try skyClickEventRecipe(clickCount: 1, profile: .popup)
        var skyEvents: [SkyClickEventKind] = []
        var publicEvents: [SkyClickEventKind] = []
        try dispatchSkyClickEvents(recipe, post: { step in
            XCTAssertEqual(step.pointKind, .target)
            try postSkyClickEvent(profile: .popup, button: .left, skyLight: {
                skyEvents.append(step.kind)
            }, publicPID: {
                publicEvents.append(step.kind)
            })
        }, wait: { _ in })
        XCTAssertEqual(skyEvents, [.moved, .down, .up])
        XCTAssertTrue(publicEvents.isEmpty)
    }

    func testStandardDeliveryStillUsesBothChannelsOnlyForLeftButton() throws {
        for button in [MouseButtonKind.left, .right] {
            var channels: [String] = []
            try postSkyClickEvent(profile: .standard, button: button, skyLight: {
                channels.append("sky")
            }, publicPID: {
                channels.append("public")
            })
            XCTAssertEqual(channels, button == .left ? ["sky", "public"] : ["sky"])
        }
    }

    func testPopupStillRevalidatesBeforeDownAndAlwaysReleasesSubmittedDown() throws {
        for invalidateAfter in [SkyClickEventKind.moved, .down] {
            var valid = true
            var posted: [SkyClickEventKind] = []
            func run() throws {
                try dispatchSkyClickEvents(
                    skyClickEventRecipe(clickCount: 1, profile: .popup),
                    validateBeforeSubmission: {
                        if !valid {
                            throw ComputerUseError.message("receiver changed")
                        }
                    }, post: { step in
                        posted.append(step.kind)
                        if step.kind == invalidateAfter {
                            valid = false
                        }
                    }, wait: { _ in }
                )
            }
            if invalidateAfter == .moved {
                XCTAssertThrowsError(try run())
                XCTAssertEqual(posted, [.moved])
            } else {
                XCTAssertNoThrow(try run())
                XCTAssertEqual(posted, [.moved, .down, .up])
            }
        }
    }

    func testDeliveryFailureNeverFallsBackToPublicPID() {
        for profile in [SkyClickProfile.standard, .popup] {
            XCTAssertThrowsError(try postSkyClickEvent(profile: profile, button: .left, skyLight: {
                throw ComputerUseError.message("delivery unknown")
            }, publicPID: {
                XCTFail("Unknown delivery must not fall back")
            }))
        }
    }

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
                if !valid {
                    throw ComputerUseError.message("receiver changed")
                }
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
                    if !valid {
                        throw ComputerUseError.message("popup closed after down")
                    }
                }, post: { step in
                    posted.append(step)
                    if step.kind == .down, step.pointKind == invalidatingPoint {
                        valid = false
                    }
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
