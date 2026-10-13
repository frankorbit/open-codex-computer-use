import AppKit
@testable import OpenComputerUseKit
import XCTest

final class PopupCaptureGeometryTests: XCTestCase {
    private let window = CGRect(x: -300, y: -41, width: 466, height: 671)

    private func observation(
        captureBounds: CGRect?, pixels: CGSize = CGSize(width: 932, height: 1260)
    ) -> HoverPopupObservation {
        HoverPopupObservation(
            token: UUID().uuidString, windowID: 2, pid: 11, bounds: window,
            captureBounds: captureBounds, imageData: Data([1]), pixelSize: pixels,
            permitsInput: true, permitsBackgroundInput: true
        )
    }

    private func snapshot() -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(name: "fixture", bundleIdentifier: "test.geometry", pid: 11,
                                      runningApplication: .current),
            windowTitle: "fixture", windowBounds: CGRect(x: -500, y: -100, width: 1000, height: 1000),
            targetWindowID: 1, targetWindowLayer: 0, screenshotData: nil, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil,
            windowElement: nil, elements: [:]
        )
    }

    private func point(_ pixel: CGPoint, popup: HoverPopupObservation) throws -> CGPoint {
        let state = snapshot()
        let method = try XCTUnwrap(popup.clickMethod(policy: ExecutionPolicy.current()))
        return try HoverPopupLease(popup: popup, rootWindowID: state.targetWindowID,
                                   rootBounds: state.windowBounds, createdAt: 1, method: method)
            .globalPoint(for: pixel, snapshot: state, now: 2, method: method)
    }

    func testKnownTopCropMapsToCapturedRegionInsteadOfStretchingFullWindow() throws {
        let popup = observation(captureBounds: CGRect(x: -300, y: 0, width: 466, height: 630))
        XCTAssertEqual(try point(CGPoint(x: 280, y: 792), popup: popup), CGPoint(x: -160, y: 396))
        XCTAssertEqual(try point(.zero, popup: popup), CGPoint(x: -300, y: 0))
        XCTAssertEqual(popup.bounds, window)
    }

    func testFullWindowOnNegativeDisplayCoordinatesIsNotClamped() throws {
        let popup = observation(captureBounds: window, pixels: CGSize(width: 932, height: 1342))
        XCTAssertEqual(try point(.zero, popup: popup), CGPoint(x: -300, y: -41))
        XCTAssertEqual(try point(CGPoint(x: 280, y: 792), popup: popup), CGPoint(x: -160, y: 355))
    }

    func testResizedImageAndLeftCropKeepIndependentOffsetAndScale() throws {
        let popup = observation(captureBounds: CGRect(x: -200, y: 10, width: 200, height: 400),
                                pixels: CGSize(width: 100, height: 200))
        XCTAssertEqual(try point(CGPoint(x: 25, y: 100), popup: popup), CGPoint(x: -150, y: 210))
        for pixel in [CGPoint(x: -1, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 200)] {
            XCTAssertThrowsError(try point(pixel, popup: popup))
        }
    }

    func testOutputWithDifferentAxisScalesMapsWithoutAssumingRetinaFactor() throws {
        let popup = observation(captureBounds: CGRect(x: -200, y: 10, width: 200, height: 400),
                                pixels: CGSize(width: 400, height: 400))
        XCTAssertEqual(try point(CGPoint(x: 100, y: 100), popup: popup), CGPoint(x: -150, y: 110))
    }

    func testUnknownOrInvalidCaptureRegionCannotAdvertiseOrCacheClickToken() throws {
        let regions: [CGRect?] = [nil, .zero, window.offsetBy(dx: 1, dy: 0),
                                  CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)]
        for region in regions {
            let popup = observation(captureBounds: region)
            for policy in [ExecutionPolicy.background, .compatible] {
                XCTAssertNil(popup.clickMethod(policy: policy))
                let content = popup.content(policy: policy)
                XCTAssertEqual(content.count, 2)
                let text = content.compactMap { $0.dictionary["text"] as? String }.joined()
                XCTAssertFalse(text.contains("popup_token="))
                let metadata = (content.last?.dictionary["_meta"] as? [String: Any])?["ocuPopup"] as? [String: Any]
                XCTAssertNil(metadata?["token"])
                XCTAssertEqual(metadata?["observationOnly"] as? Bool, true)
            }
            var cache = HoverPopupCache()
            cache.record([popup], snapshot: snapshot(), now: 1)
            XCTAssertThrowsError(try cache.take(popup.token))
        }
    }
}
