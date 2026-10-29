import CoreGraphics
import Foundation
@testable import OpenComputerUseKit
import XCTest

final class PopupCaptureDiagnosticTests: XCTestCase {
    private typealias Observation = HoverPopupObservation
    private typealias Window = Observation.Window
    private let root = Window(windowID: 10, pid: 123, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    private let popup = Window(windowID: 11, pid: 123, bounds: CGRect(x: 50, y: 50, width: 100, height: 100))

    func testRootEvidenceDistinguishesMissingRejectedAndInvisibleRecordsWithoutPrivateContents() {
        let info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: root.windowID),
            kCGWindowOwnerPID as String: NSNumber(value: root.pid),
            kCGWindowBounds as String: root.bounds.dictionaryRepresentation,
            kCGWindowAlpha as String: NSNumber(value: 1.0),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowIsOnscreen as String: kCFBooleanTrue as Any,
            kCGWindowName as String: "PRIVATE_TITLE_SENTINEL"
        ]
        func evidence(_ records: [[String: Any]]) -> String {
            let result = HoverPopupDiagnostics.rootWindowEvidence(rootID: root.windowID, info: records)
            XCTAssertFalse(result.contains("PRIVATE"))
            return result
        }
        XCTAssertEqual(evidence([]), "stage=recordMissing recordCount=0")
        XCTAssertTrue(evidence([info]).contains("stage=visible"))
        var changed = info
        changed[kCGWindowAlpha as String] = NSNumber(value: 0)
        XCTAssertTrue(evidence([changed]).contains("stage=notVisible"))
        XCTAssertTrue(evidence([changed]).contains("alpha=number:0.0"))
        changed = info
        changed.removeValue(forKey: kCGWindowIsOnscreen as String)
        XCTAssertTrue(evidence([changed]).contains("stage=recordRejected"))
        XCTAssertTrue(evidence([changed]).contains("onscreen=missing"))
        changed[kCGWindowAlpha as String] = "PRIVATE_INVALID_SENTINEL"
        XCTAssertTrue(evidence([changed]).contains("alpha=unsupported"))
        changed = info
        changed[kCGWindowIsOnscreen as String] = NSNumber(value: 2)
        XCTAssertTrue(evidence([changed]).contains("onscreen=number:2.0"))
        XCTAssertTrue(evidence([changed]).contains("stage=recordRejected"))
        changed[kCGWindowNumber as String] = NSNumber(value: popup.windowID)
        XCTAssertEqual(evidence([changed]), "stage=recordMissing recordCount=1")
    }

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
