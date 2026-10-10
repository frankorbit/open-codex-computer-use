import CoreGraphics
import Foundation
@testable import OpenComputerUseKit
import XCTest

final class HoverPopupObservationTests: XCTestCase {
    private typealias Observation = HoverPopupObservation
    private typealias Window = Observation.Window
    private typealias State = Observation.State

    private let root = Window(windowID: 10, pid: 123, bounds: CGRect(x: -800, y: 100, width: 600, height: 400))
    private let popup = Window(windowID: 11, pid: 123, bounds: CGRect(x: -240, y: 140, width: 120, height: 60))

    private func imageData() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        return try XCTUnwrap(try encodeScreenshot(
            for: XCTUnwrap(context.makeImage()), config: ImageCaptureConfig(maxDimension: 40)
        ).data)
    }

    private func capture(
        state: @escaping () -> State?, image: @escaping (Window) throws -> Data?
    ) -> [Observation] {
        Observation.capture(
            rootWindowID: root.windowID, pid: root.pid, rootBounds: root.bounds,
            dependencies: .init(readState: state, captureImage: image)
        )
    }

    func testAXLessQtCandidateIncludesEncodedDimensionsAndSeparateCoordinateContract() throws {
        let data = try imageData()
        let state = State(windows: [popup, root])
        let first = try XCTUnwrap(capture(state: { state }, image: { _ in data }).first)
        let second = try XCTUnwrap(capture(state: { state }, image: { _ in data }).first)
        XCTAssertNotNil(UUID(uuidString: first.token))
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(first.windowID, popup.windowID)
        XCTAssertEqual(first.pid, popup.pid)
        XCTAssertEqual(first.bounds, popup.bounds)
        XCTAssertEqual(first.pixelSize, CGSize(width: 40, height: 20))
        XCTAssertEqual(first.imageData, data)
        XCTAssertEqual(first.content.count, 2)
        let text = try XCTUnwrap(first.content.first?.dictionary["text"] as? String)
        XCTAssertEqual(text.split(separator: "\n").count, 3)
        for fragment in [
            first.token,
            "windowID=11",
            "pid=123",
            "bounds=(-240.0, 140.0, 120.0, 60.0)",
            "(40.0, 20.0)",
            "popup_token",
            "app.click([x,y],{popupToken:",
            "clickMethod:\"global\"",
            "Main coordinates unchanged",
            "Candidate only, not parent proof"
        ] {
            XCTAssertTrue(text.contains(fragment), fragment)
        }
        XCTAssertEqual(first.content.last?.dictionary["data"] as? String, data.base64EncodedString())
    }

    func testOnlyExplicitStandardAXWindowIsExcluded() {
        XCTAssertTrue(Observation.excludesAXWindow(subrole: "AXStandardWindow"))
        for subrole: String? in [nil, "", "AXFloatingWindow", "AXDialog", "AXSystemDialog", "QtPopup"] {
            XCTAssertFalse(Observation.excludesAXWindow(subrole: subrole))
        }
    }

    func testPopupMetadataBelongsOnlyToItsImageAndPreservesMIME() throws {
        let data = try imageData()
        let first = Observation(
            token: UUID().uuidString, windowID: 11, pid: 123, bounds: popup.bounds,
            imageData: data, pixelSize: CGSize(width: 40, height: 20)
        )
        // 此测试只验证包装逻辑；JPEG 头用于确保不把原 MIME 强制改成 PNG。
        let second = Observation(
            token: UUID().uuidString, windowID: 12, pid: 123, bounds: popup.bounds,
            imageData: Data([0xFF, 0xD8, 0xFF]), pixelSize: CGSize(width: 40, height: 20)
        )
        let main = ToolResultContentItem.screenshotImage(data)
        XCTAssertNil(main.dictionary["_meta"])
        for observation in [first, second] {
            XCTAssertNil(observation.content.first?.dictionary["_meta"])
            let image = try XCTUnwrap(observation.content.last?.dictionary)
            let metadata = try XCTUnwrap(image["_meta"] as? [String: Any])
            let popupMetadata = try XCTUnwrap(metadata["ocuPopup"] as? [String: Any])
            XCTAssertEqual(popupMetadata["token"] as? String, observation.token)
            XCTAssertEqual(popupMetadata["windowID"] as? CGWindowID, observation.windowID)
            XCTAssertEqual(popupMetadata["pid"] as? pid_t, observation.pid)
            XCTAssertEqual(image["data"] as? String, observation.imageData.base64EncodedString())
            XCTAssertEqual(image["type"] as? String, "image")
        }
        XCTAssertEqual(first.content.last?.dictionary["mimeType"] as? String, "image/png")
        XCTAssertEqual(second.content.last?.dictionary["mimeType"] as? String, "image/jpeg")
    }

    func testExcludesIndependentAXWindowsOtherPIDsBehindRootAndUnrelatedGeometry() throws {
        let data = try imageData()
        let independent = Window(windowID: 12, pid: root.pid, bounds: popup.bounds)
        let otherPID = Window(windowID: 13, pid: 999, bounds: popup.bounds)
        let remote = Window(windowID: 14, pid: root.pid, bounds: popup.bounds.offsetBy(dx: 2000, dy: 0))
        let behind = Window(windowID: 15, pid: root.pid, bounds: popup.bounds)
        let state = State(windows: [independent, otherPID, remote, popup, root, behind], independentWindowIDs: [12])
        var attempts: [CGWindowID] = []
        let results = capture(state: { state }, image: { window in attempts.append(window.windowID); return data })
        XCTAssertEqual(attempts, [popup.windowID])
        XCTAssertEqual(results.map(\.windowID), [popup.windowID])
        let unresolvedAXWindow = State(windows: [popup, root], independentWindowBounds: [popup.bounds])
        XCTAssertTrue(capture(
            state: { unresolvedAXWindow },
            image: { _ in XCTFail("Independent AX window"); return data }
        ).isEmpty)
    }

    func testRejectsInvisibleTransparentInvalidAndDuplicateWindowsBeforeCapture() throws {
        let data = try imageData()
        var hidden = popup
        hidden.isOnscreen = false
        var transparent = popup
        transparent.alpha = 0
        var invalidAlpha = popup
        invalidAlpha.alpha = .nan
        var desktop = popup
        desktop.layer = -1
        let invalidBounds = Window(
            windowID: 11,
            pid: root.pid,
            bounds: CGRect(x: CGFloat.infinity, y: 100, width: 1, height: 1)
        )
        for windows in [
            [hidden, root],
            [transparent, root],
            [invalidAlpha, root],
            [desktop, root],
            [invalidBounds, root],
            [popup, popup, root],
            [popup, root, root]
        ] {
            XCTAssertTrue(capture(state: { State(windows: windows) }, image: { _ in
                XCTFail("Invalid candidate must not be captured"); return data
            }).isEmpty)
        }
    }
}

extension HoverPopupObservationTests {
    func testGeometryRequiresPositiveProjectionOverlapAndBoundedEdgeGap() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(Observation.geometricallyRelated(CGRect(x: 100, y: 20, width: 50, height: 50), bounds))
        XCTAssertTrue(Observation.geometricallyRelated(CGRect(x: 116, y: 20, width: 50, height: 50), bounds))
        XCTAssertFalse(Observation.geometricallyRelated(CGRect(x: 117, y: 20, width: 50, height: 50), bounds))
        XCTAssertFalse(Observation.geometricallyRelated(CGRect(x: 105, y: 105, width: 50, height: 50), bounds))
        XCTAssertFalse(Observation.geometricallyRelated(.zero, bounds))
        XCTAssertFalse(Observation.geometricallyRelated(CGRect(x: 0, y: 0, width: -10, height: 10), bounds))
    }

    func testRootOrForegroundChangeAtAnyReadDiscardsEntireBatch() throws {
        let data = try imageData()
        let initial = State(windows: [popup, root])
        let moved = Window(windowID: root.windowID, pid: root.pid, bounds: root.bounds.offsetBy(dx: 1, dy: 0))
        let reused = Window(windowID: root.windowID, pid: 999, bounds: root.bounds)
        var hidden = root
        hidden.isOnscreen = false
        let invalidStates: [State?] = [
            nil,
            State(windows: [popup]),
            State(windows: [popup, moved]),
            State(windows: [popup, reused]),
            State(windows: [popup, hidden]),
            State(windows: [popup, root], rootIsForeground: false)
        ]
        // 初读、截图前、截图后、整批返回前，每个阶段都必须守住 root。
        for invalid in invalidStates {
            for failedRead in 1 ... 4 {
                var reads = 0
                var captures = 0
                let results = capture(state: {
                    reads += 1
                    return reads == failedRead ? invalid : initial
                }, image: { _ in captures += 1; return data })
                XCTAssertTrue(results.isEmpty, "read=\(failedRead)")
                if failedRead <= 2 { XCTAssertEqual(captures, 0) }
            }
        }
    }

    func testPopupIdentityGeometryOrderAndAXClassificationAreRecheckedAfterCapture() throws {
        let data = try imageData()
        let initial = State(windows: [popup, root])
        let moved = Window(windowID: popup.windowID, pid: popup.pid, bounds: popup.bounds.offsetBy(dx: 1, dy: 0))
        let resized = Window(
            windowID: popup.windowID,
            pid: popup.pid,
            bounds: CGRect(x: -240, y: 140, width: 121, height: 60)
        )
        let reused = Window(windowID: popup.windowID, pid: 999, bounds: popup.bounds)
        var invisible = popup
        invisible.isOnscreen = false
        for changed in [
            State(windows: [root]),
            State(windows: [moved, root]),
            State(windows: [resized, root]),
            State(windows: [reused, root]),
            State(windows: [root, popup]),
            State(windows: [
                invisible,
                root
            ]),
            State(windows: [popup, root], independentWindowIDs: [popup.windowID])
        ] {
            var state = initial
            XCTAssertTrue(capture(state: { state }, image: { _ in state = changed; return data }).isEmpty)
        }
    }

    func testCandidateChangedBeforeCaptureIsNeverPhotographed() throws {
        let data = try imageData()
        var reads = 0
        let results = capture(state: {
            reads += 1
            return State(windows: reads == 1 ? [self.popup, self.root] : [self.root])
        }, image: { _ in XCTFail("Stale candidate"); return data })
        XCTAssertTrue(results.isEmpty)
    }

    func testFinalReadDropsEarlierPopupThatClosedDuringLaterCapture() throws {
        let data = try imageData()
        let second = Window(windowID: 12, pid: popup.pid, bounds: popup.bounds.offsetBy(dx: -100, dy: 0))
        var state = State(windows: [popup, second, root])
        let results = capture(state: { state }, image: { window in
            if window.windowID == second.windowID { state = State(windows: [second, self.root]) }
            return data
        })
        XCTAssertEqual(results.map(\.windowID), [second.windowID])
    }

    func testLimitsBothImagesAndAttemptsToFourInFrontToBackOrder() throws {
        let data = try imageData()
        let popups = (11 ... 20).map { Window(windowID: CGWindowID($0), pid: root.pid, bounds: popup.bounds) }
        let state = State(windows: popups + [root])
        var attempts: [CGWindowID] = []
        let results = capture(state: { state }, image: { window in attempts.append(window.windowID); return data })
        XCTAssertEqual(attempts, [11, 12, 13, 14])
        XCTAssertEqual(results.map(\.windowID), attempts)
        attempts = []
        XCTAssertTrue(capture(state: { state }, image: { window in
            attempts.append(window.windowID); return nil
        }).isEmpty)
        XCTAssertEqual(attempts, [11, 12, 13, 14])
    }

    func testFailedOrInvalidImageCannotMintTokenOrReplayCapture() {
        for mode in 0 ... 2 {
            var attempts = 0
            let result = capture(state: { State(windows: [self.popup, self.root]) }, image: { _ in
                attempts += 1
                if mode == 0 { throw CocoaError(.fileReadUnknown) }
                return mode == 1 ? nil : Data("invalid image".utf8)
            })
            XCTAssertTrue(result.isEmpty)
            XCTAssertEqual(attempts, 1)
        }
    }

    func testWindowServerMetadataParsingRejectsUnknownOrInvalidIdentity() throws {
        let info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: popup.windowID),
            kCGWindowOwnerPID as String: NSNumber(value: popup.pid),
            kCGWindowBounds as String: popup.bounds.dictionaryRepresentation,
            kCGWindowAlpha as String: NSNumber(value: 1.0), kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowIsOnscreen as String: kCFBooleanTrue as Any
        ]
        XCTAssertEqual(try XCTUnwrap(Observation.windowInfo(info)), popup)
        for key in info.keys {
            var missing = info
            missing.removeValue(forKey: key)
            XCTAssertNil(Observation.windowInfo(missing), key)
        }
        for value: Any in [true, Double.infinity, Double.nan, -1, 1.5, Double(UInt64.max)] {
            var invalid = info
            invalid[kCGWindowNumber as String] = value
            XCTAssertNil(Observation.windowInfo(invalid))
        }
    }
}
