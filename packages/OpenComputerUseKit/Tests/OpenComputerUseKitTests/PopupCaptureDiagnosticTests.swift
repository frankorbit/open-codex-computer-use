import CoreGraphics
import Foundation
@testable import OpenComputerUseKit
import XCTest

final class PopupCaptureDiagnosticTests: XCTestCase {
    private typealias Observation = HoverPopupObservation
    private typealias Window = Observation.Window
    private let root = Window(windowID: 10, pid: 123, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    private let popup = Window(windowID: 11, pid: 123, bounds: CGRect(x: 50, y: 50, width: 100, height: 100))

    private func image() throws -> Observation.CapturedImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try XCTUnwrap(encodeScreenshot(for: XCTUnwrap(context.makeImage()), config: .defaults).data)
        return .init(data: data, captureBounds: popup.bounds)
    }

    func testChangedCandidateReportsExistingMetadataWithoutExtraReadsOrCaptureRetries() throws {
        let image = try image()
        for changedRead in [3, 4] {
            for disappears in [false, true] {
                var reads = 0
                var captures = 0
                var changed = popup
                changed.alpha = 0.5
                var reasons: [HoverPopupDiagnostics.Reason] = []
                let worker = HoverPopupCaptureWorker()
                let budget = HoverPopupBudget(duration: 1)
                let result = worker.capture(budget: budget) {
                    Observation.captureResult(
                        rootWindowID: self.root.windowID, pid: self.root.pid, rootBounds: self.root.bounds,
                        dependencies: .init(readState: {
                            reads += 1
                            let windows = reads < changedRead ? [self.popup, self.root]
                                : (disappears ? [self.root] : [changed, self.root])
                            return .init(windows: windows)
                        }, captureImage: { _ in captures += 1; return image }), budget: budget,
                        report: { reason, expected, observed in
                            reasons.append(reason)
                            XCTAssertEqual(expected, self.popup)
                            XCTAssertEqual(observed, disappears ? nil : changed)
                        }
                    )
                }
                XCTAssertTrue(result.isIncomplete)
                XCTAssertTrue(result.popups.isEmpty)
                XCTAssertEqual(captures, 1)
                XCTAssertEqual(reads, 4)
                XCTAssertEqual(reasons, [changedRead == 3
                        ? .candidateChangedAfterCapture : .candidateChangedBeforeReturn])
            }
        }
    }

    func testMissingInvalidAndThrownImagesRemainIncompleteWithoutRetry() {
        struct CaptureFailure: Error {}
        for mode in 0 ..< 3 {
            var reasons: [HoverPopupDiagnostics.Reason] = []
            var captures = 0
            var reads = 0
            let result = Observation.captureResult(
                rootWindowID: root.windowID, pid: root.pid, rootBounds: root.bounds,
                dependencies: .init(readState: {
                    reads += 1
                    return .init(windows: [self.popup, self.root])
                }, captureImage: { _ in
                    captures += 1
                    if mode == 2 { throw CaptureFailure() }
                    return mode == 0 ? nil : .init(data: Data([1, 2, 3]), captureBounds: self.popup.bounds)
                }), report: { reason, _, _ in reasons.append(reason) }
            )
            XCTAssertTrue(result.isIncomplete)
            XCTAssertTrue(result.popups.isEmpty)
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(reads, 4)
            XCTAssertEqual(reasons, mode == 0 ? [.imageUnavailable]
                : (mode == 1 ? [.imageDataInvalid] : [.imageCaptureFailed, .imageUnavailable]))
        }
    }

    func testSuccessfulObservationHasNoDiagnosticAndPreservesCaptureContract() throws {
        let image = try image()
        var reads = 0
        let result = Observation.captureResult(
            rootWindowID: root.windowID, pid: root.pid, rootBounds: root.bounds,
            allowBackgroundInput: true,
            dependencies: .init(readState: {
                reads += 1
                return .init(windows: [self.popup, self.root])
            }, captureImage: { _ in image }),
            report: { _, _, _ in XCTFail("Successful observation") }
        )
        XCTAssertFalse(result.isIncomplete)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(result.popups.count, 1)
        XCTAssertEqual(result.popups.first?.imageData, image.data)
        XCTAssertEqual(result.popups.first?.captureBounds, popup.bounds)
        XCTAssertEqual(result.popups.first?.permitsBackgroundInput, true)
    }

    func testExpiredBudgetDoesNotReadStateOrCapture() {
        let result = Observation.captureResult(
            rootWindowID: root.windowID, pid: root.pid, rootBounds: root.bounds,
            dependencies: .init(readState: { XCTFail("Expired"); return nil },
                                captureImage: { _ in XCTFail("Expired"); return nil }),
            budget: .init(duration: 0)
        )
        XCTAssertTrue(result.isIncomplete)
        XCTAssertTrue(result.popups.isEmpty)
    }
}
