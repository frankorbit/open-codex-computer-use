import Foundation
@testable import OpenComputerUseKit
import XCTest

final class SkyKeyboardFocusTests: XCTestCase {
    private enum Failure: Error { case prepare, input, cleanup }

    func testPreparationFailureCleansUpWithoutSendingInput() {
        var cleanupCount = 0
        XCTAssertThrowsError(try withSkyKeyboardFocus(
            begin: { 1 }, prepare: { _ in throw Failure.prepare },
            deliver: { XCTFail("must not deliver after focus failure") },
            end: { _ in cleanupCount += 1 }
        )) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(cleanupCount, 1)
    }

    func testInputFailureCleansUpExactlyOnceWithoutReplay() {
        var attempts = 0
        var cleanupCount = 0
        XCTAssertThrowsError(try withSkyKeyboardFocus(
            begin: { 1 }, prepare: { _ in },
            deliver: { attempts += 1; throw Failure.input },
            end: { _ in cleanupCount += 1 }
        )) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(cleanupCount, 1)
    }

    func testCleanupFailureIsSurfacedEvenWhenInputAlsoFailed() {
        for inputFails in [false, true] {
            var attempts = 0
            var cleanupCount = 0
            XCTAssertThrowsError(try withSkyKeyboardFocus(
                begin: { 1 }, prepare: { _ in },
                deliver: { attempts += 1; if inputFails { throw Failure.input } },
                end: { _ in cleanupCount += 1; throw Failure.cleanup }
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("release synthetic focus"))
                XCTAssertTrue(error.localizedDescription.contains("unknown"))
            }
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(cleanupCount, 1)
        }
    }

    func testProductionDispatcherContinuesAfterTargetBecomesForeground() throws {
        for transitionPhase in ["prepare", "input"] {
            var frontmost: pid_t? = 1
            var phases: [String] = []
            let backend = backend(frontmost: { frontmost }, phases: { phases.append($0) }, prepare: {
                if transitionPhase == "prepare" { frontmost = 2 }
            })
            try SkyKeyboardDispatcher.deliver(to: .init(windowID: 42, pid: 2), backend: backend) { validate in
                try deliverKeyboardTextChunks([[65], [66]], validateReceiver: validate, submit: { _ in
                    phases.append("input")
                    frontmost = 2
                })
            }
            XCTAssertEqual(phases.count(where: { $0 == "input" }), 2)
            XCTAssertEqual(phases.count(where: { $0 == "begin" }), 1)
            XCTAssertEqual(phases.last, "end")
            XCTAssertEqual(frontmost, 2)
        }
    }

    func testProductionForegroundRouteSkipsSyntheticFocusButStillValidates() throws {
        var phases: [String] = []
        let backend = backend(frontmost: { 2 }, phases: { phases.append($0) })
        try SkyKeyboardDispatcher.deliver(to: .init(windowID: 42, pid: 2), backend: backend) { validate in
            try validate()
            phases.append("input")
        }
        XCTAssertEqual(phases, ["validate", "validate", "input"])
    }

    func testProductionDispatcherStopsChangedWindowAfterPartialInputAndCleansUp() {
        var phases: [String] = []
        var valid = true
        var backend = backend(frontmost: { 1 }, phases: { phases.append($0) })
        backend.validateTarget = { _ in
            if !valid { throw Failure.input }
        }
        XCTAssertThrowsError(try SkyKeyboardDispatcher.deliver(
            to: .init(windowID: 42, pid: 2), backend: backend
        ) { validate in
            try deliverKeyboardTextChunks([[65], [66]], validateReceiver: validate, submit: { _ in
                phases.append("input")
                valid = false
            })
        }) { XCTAssertTrue($0.localizedDescription.contains("some text may already")) }
        XCTAssertEqual(phases.count(where: { $0 == "input" }), 1)
        XCTAssertEqual(phases.count(where: { $0 == "end" }), 1)
    }

    func testProductionPreparationFailureCleansUpWithoutInput() {
        var phases: [String] = []
        let backend = backend(frontmost: { 1 }, phases: { phases.append($0) }, prepare: { throw Failure.prepare })
        XCTAssertThrowsError(try SkyKeyboardDispatcher.deliver(
            to: .init(windowID: 42, pid: 2), backend: backend
        ) { _ in XCTFail("must not send") })
        XCTAssertEqual(phases.count(where: { $0 == "end" }), 1)
    }

    private func backend(
        frontmost: @escaping () -> pid_t?, phases: @escaping (String) -> Void,
        prepare: @escaping () throws -> Void = {}
    ) -> SkyKeyboardDeliveryBackend {
        SkyKeyboardDeliveryBackend(
            frontmostPID: frontmost,
            validateTarget: { target in XCTAssertEqual(target.windowID, 42); phases("validate") },
            requireCapability: { phases("capability") },
            begin: { target in
                phases("begin")
                return SkyLightSyntheticFocusContext(deactivateTarget: .init(
                    psn: [], windowID: target.windowID, focused: false
                ))
            },
            makeKey: { _ in phases("prepare"); try prepare() },
            waitForKey: { _ in phases("settle") },
            releaseWait: { phases("release_wait") },
            end: { _ in phases("end") }
        )
    }
}
