import CoreGraphics
@testable import OpenComputerUseKit
import XCTest

final class WindowSharingIndicatorTests: XCTestCase {
    private typealias Indicator = WindowSharingIndicator
    // Measured on macOS 26 while streaming an Xcode window at (369, 30, 1551, 890).
    private let root = Indicator.Captured(windowID: 910, pid: 2007)
    private let rootBounds = CGRect(x: 369, y: 30, width: 1551, height: 890)
    private let indicatorBounds = CGRect(x: 385, y: 46, width: 66, height: 20)

    private func row(id: Int, pid: Int, rect: CGRect, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: rect.dictionaryRepresentation, kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowIsOnscreen as String: NSNumber(value: true), kCGWindowAlpha as String: NSNumber(value: 1)]
    }

    func testMeasuredIndicatorMatchesOnlyInTheStreamedWindowCorner() {
        func matches(id: CGWindowID = 2395, pid: pid_t = 2007, bounds: CGRect, layer: Int = 0) -> Bool {
            Indicator.matches(windowID: id, pid: pid, bounds: bounds, layer: layer, root: root, rootBounds: rootBounds)
        }
        XCTAssertTrue(matches(bounds: indicatorBounds))
        XCTAssertFalse(matches(pid: 4321, bounds: indicatorBounds))
        XCTAssertFalse(matches(id: 910, bounds: indicatorBounds))
        XCTAssertFalse(matches(bounds: indicatorBounds, layer: 101))
        // A menu, sheet or popover of the app is larger or elsewhere and stays a popup.
        XCTAssertFalse(matches(bounds: CGRect(x: 385, y: 46, width: 260, height: 180)))
        XCTAssertFalse(matches(bounds: CGRect(x: 900, y: 46, width: 66, height: 20)))
        XCTAssertFalse(matches(bounds: CGRect(x: 385, y: 400, width: 66, height: 20)))
        XCTAssertFalse(matches(bounds: CGRect(x: 360, y: 46, width: 66, height: 20)))
    }

    func testRecognizedOnlyWhileThisProcessStreamsAWindowOfTheSameApp() {
        let indicator = row(id: 2395, pid: 2007, rect: indicatorBounds)
        let windows = [indicator, row(id: 910, pid: 2007, rect: rootBounds)]
        XCTAssertFalse(Indicator.isIndicator(indicator, windows: windows, captured: []))
        XCTAssertTrue(Indicator.isIndicator(indicator, windows: windows, captured: [root]))
        XCTAssertFalse(Indicator.isIndicator(indicator, windows: windows, captured: [.init(windowID: 910, pid: 99)]))
        // The streamed window may be missing from a narrowed list; its bounds are read directly.
        XCTAssertTrue(Indicator.isIndicator(indicator, windows: [indicator], captured: [root]) { _, id in
            id == 910 ? [self.row(id: 910, pid: 2007, rect: self.rootBounds)] : nil
        })
        XCTAssertFalse(Indicator.isIndicator(indicator, windows: [indicator], captured: [root]) { _, _ in nil })
    }

    func testPopupCandidatesSkipTheIndicatorOnlyWhileStreaming() {
        typealias Observation = HoverPopupObservation
        let rootWindow = Observation.Window(windowID: 9910, pid: 9007, bounds: rootBounds)
        let indicator = Observation.Window(windowID: 9911, pid: 9007, bounds: indicatorBounds)
        let popover = Observation.Window(
            windowID: 9912, pid: 9007, bounds: CGRect(x: 420, y: 60, width: 260, height: 180)
        )
        let state = Observation.State(windows: [indicator, popover, rootWindow])
        let candidates = { state.candidates(rootWindowID: 9910, pid: 9007, rootBounds: self.rootBounds) }

        XCTAssertEqual(candidates(), [indicator, popover])
        Indicator.captureStarted(windowID: 9910, pid: 9007)
        defer { Indicator.captureEnded(windowID: 9910, pid: 9007) }
        XCTAssertEqual(candidates(), [popover])
        Indicator.captureEnded(windowID: 9910, pid: 9007)
        XCTAssertEqual(candidates(), [indicator, popover])
    }

    func testCoordinateClickIsNotBlockedByTheIndicatorButStillByARealWindow() throws {
        let bounds = CGRect(x: -900, y: 120, width: 800, height: 600)
        let point = CGPoint(x: -860, y: 146)
        let target = row(id: 9942, pid: 9234, rect: bounds)
        let indicator = row(id: 9943, pid: 9234, rect: CGRect(x: -884, y: 136, width: 66, height: 20))
        let sheet = row(id: 9944, pid: 9234, rect: CGRect(x: -890, y: 130, width: 400, height: 300))
        func validate(_ above: [[String: Any]]) throws {
            try validateCoordinateWindow(
                windowID: 9942, pid: 9234, bounds: bounds, point: point, windows: above + [target],
                requireUnoccludedPoint: false, spacesForWindow: { _ in [1] },
                backgroundWindows: { _ in .onScreenAbove(above) }
            )
        }

        XCTAssertThrowsError(try validate([indicator]))
        Indicator.captureStarted(windowID: 9942, pid: 9234)
        defer { Indicator.captureEnded(windowID: 9942, pid: 9234) }
        try validate([indicator])
        XCTAssertThrowsError(try validate([sheet, indicator]))
    }
}
