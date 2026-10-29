import AppKit
@testable import OpenComputerUseKit
import XCTest

final class PopupCaptureGeometryTests: XCTestCase {
    private let window = CGRect(x: -300, y: -41, width: 466, height: 671)

    func testVisibleMenuCropUsesDisplayIntersectionAndExplicitImageOrigin() throws {
        let menu = CGRect(x: 111, y: -41, width: 416, height: 815)
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let captured = try XCTUnwrap(LivePreviewPopupRegion.visibleCaptureBounds(window: menu, displays: [display]))
        XCTAssertEqual(captured, CGRect(x: 111, y: 0, width: 416, height: 774))
        XCTAssertEqual(
            LivePreviewPopupRegion.displayRegion(window: captured, displays: [display])?.sourceRect, captured
        )
        // 预览仍不接受局部窗口；模型图才携带明确裁剪范围。
        XCTAssertNil(LivePreviewPopupRegion.displayRegion(window: menu, displays: [display]))
        let popup = HoverPopupObservation(
            token: UUID().uuidString, windowID: 2, pid: 11, bounds: menu,
            captureBounds: captured, imageData: Data([1]), pixelSize: CGSize(width: 832, height: 1548)
        )
        let mapped = try point(CGPoint(x: 200, y: 100), popup: popup)
        XCTAssertEqual(mapped.x, 211, accuracy: 0.000001)
        XCTAssertEqual(mapped.y, 50, accuracy: 0.000001)
        let text = popup.content(policy: .compatible).compactMap { $0.dictionary["text"] as? String }.joined()
        XCTAssertTrue(text.contains("Partial window image"))
        XCTAssertTrue(text.contains("off-screen or other-display content is not verified"))
    }

    func testCrossDisplayObservationSelectsOneKnownRegionWithoutStitchingOrScalingOffsets() throws {
        let displays = [CGRect(x: -1200, y: -200, width: 1200, height: 1000),
                        CGRect(x: 0, y: 0, width: 1512, height: 982)]
        let menu = CGRect(x: -300, y: -41, width: 700, height: 671)
        let region = try XCTUnwrap(LivePreviewPopupRegion.visibleCaptureBounds(window: menu, displays: displays))
        XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 400, height: 630))
        let plan = try XCTUnwrap(LivePreviewPopupRegion.displayRegion(window: region, displays: displays))
        XCTAssertEqual(plan.index, 1)
        XCTAssertEqual(plan.sourceRect, region)
        let negative = CGRect(x: -1100, y: -250, width: 200, height: 400)
        let clipped = try XCTUnwrap(LivePreviewPopupRegion.visibleCaptureBounds(window: negative, displays: displays))
        XCTAssertEqual(clipped, CGRect(x: -1100, y: -200, width: 200, height: 350))
        XCTAssertEqual(LivePreviewPopupRegion.displayRegion(window: clipped, displays: displays)?.sourceRect,
                       CGRect(x: 100, y: 0, width: 200, height: 350))
        let fullyVisible = CGRect(x: -600, y: -41, width: 466, height: 671)
        XCTAssertEqual(
            LivePreviewPopupRegion.visibleCaptureBounds(window: fullyVisible, displays: displays), fullyVisible
        )
    }

    func testInvisibleOrInvalidWindowStillHasNoCaptureRegion() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        for rectangle in [CGRect(x: -500, y: -500, width: 200, height: 100), CGRect.zero,
                          CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            XCTAssertNil(LivePreviewPopupRegion.visibleCaptureBounds(window: rectangle, displays: displays))
        }
        XCTAssertNil(LivePreviewPopupRegion.visibleCaptureBounds(window: window, displays: []))
    }

    func testCroppedObservationKeepsSingleUseLeaseAndNeverReplaysAfterReadBackFailure() throws {
        let captured = try XCTUnwrap(LivePreviewPopupRegion.visibleCaptureBounds(
            window: window, displays: [CGRect(x: -1200, y: 0, width: 2400, height: 900)]
        ))
        let popup = observation(captureBounds: captured)
        let state = snapshot()
        var cache = HoverPopupCache()
        cache.record([popup], snapshot: state, now: 1)
        let lease = try cache.take(popup.token)
        let point = try lease.globalPoint(for: CGPoint(x: 280, y: 792), snapshot: state,
                                          now: 2, method: lease.method)
        XCTAssertEqual(point, CGPoint(x: -160, y: 396))
        var submitted = 0
        XCTAssertThrowsError(try dispatchPopupClick(method: lease.method, validate: {}, submit: {
            submitted += 1
        }, readBack: { throw ComputerUseError.message("capture failed") }))
        XCTAssertEqual(submitted, 1)
        XCTAssertThrowsError(try cache.take(popup.token))
        XCTAssertThrowsError(try lease.globalPoint(for: .zero, snapshot: state, now: 32, method: lease.method))

        cache.record([popup], snapshot: state, now: 3)
        _ = try cache.take(popup.token)
        XCTAssertThrowsError(try dispatchPopupClick(method: lease.method, validate: {
            throw ComputerUseError.stateUnavailable("receiver changed")
        }, submit: { submitted += 1 }, readBack: {}))
        XCTAssertEqual(submitted, 1)
        XCTAssertThrowsError(try cache.take(popup.token))
    }

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
