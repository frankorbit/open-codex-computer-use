import CoreGraphics
@testable import OpenComputerUseKit
import XCTest

final class WindowCaptureGeometryTests: XCTestCase {
    private func image(_ size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    func testPartialOffscreenAndCrossDisplaySkipHardwareEvenWithMatchingAspect() throws {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
        for origin in [
            CGPoint(x: 436, y: 33),
            CGPoint(x: -2100, y: 33),
            CGPoint(x: -300, y: 33),
            CGPoint(x: 0, y: -100),
            CGPoint(x: 0, y: 800)
        ] {
            let bounds = CGRect(origin: origin, size: CGSize(width: 1512, height: 876))
            let complete = try image(bounds.size)
            var captures: [String] = []
            let result = WindowCaptureGeometry.capture(bounds: bounds, displayBounds: displays, hardware: {
                captures.append("hardware")
                return complete
            }, fullWindow: {
                captures.append("full")
                return complete
            })
            XCTAssertNotNil(result)
            XCTAssertEqual(captures, ["full"])
        }
    }

    func testNormalWindowRetainsHardwareAndMalformedHardwareFallsBackOnce() throws {
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for size in [CGSize(width: 1600, height: 1200), CGSize(width: 1280, height: 1042)] {
            var calls: [String] = []
            let hardware = try image(size)
            let complete = try image(bounds.size)
            XCTAssertNotNil(WindowCaptureGeometry.capture(bounds: bounds, displayBounds: [display], hardware: {
                calls.append("hardware"); return hardware
            }, fullWindow: {
                calls.append("full"); return complete
            }))
            XCTAssertEqual(calls, size.width == 1600 ? ["hardware"] : ["hardware", "full"])
        }
    }

    func testFailedOrMalformedFullCaptureNeverReturnsPartialImage() throws {
        let bounds = CGRect(x: 436, y: 33, width: 1512, height: 876)
        for fallback in try [image(CGSize(width: 1280, height: 1042)), nil] {
            var attempts = 0
            XCTAssertNil(WindowCaptureGeometry.capture(bounds: bounds, displayBounds: [], hardware: {
                XCTFail("unknown display coverage must not use hardware"); return nil
            }, fullWindow: { attempts += 1; return fallback }))
            XCTAssertEqual(attempts, 1)
        }
    }

    func testFullFrameMappingAcrossNegativeOriginsRetinaAndEncodingScales() throws {
        for origin in [CGPoint(x: 436, y: 33), CGPoint(x: -1920, y: -1080), CGPoint(x: 1512, y: 0)] {
            let bounds = CGRect(origin: origin, size: CGSize(width: 1512, height: 876))
            for size in [
                bounds.size,
                CGSize(width: 3024, height: 1752),
                CGSize(width: 1890, height: 1095),
                CGSize(width: 1280, height: 742)
            ] {
                let point = try WindowCaptureGeometry.windowPoint(
                    CGPoint(x: size.width / 4, y: size.height / 2),
                    pixelSize: size,
                    bounds: bounds
                )
                let global = globalPointFromWindowPoint(point, windowBounds: bounds)
                XCTAssertEqual(global.x, origin.x + 378, accuracy: 0.001)
                XCTAssertEqual(global.y, origin.y + 438, accuracy: 0.001)
            }
        }
    }

    func testClippedMissingAndInvalidCoordinatesAreRejected() {
        let bounds = CGRect(x: 436, y: 33, width: 1512, height: 876)
        for size in [CGSize(width: 1280, height: 1042), .zero, nil] {
            XCTAssertThrowsError(try WindowCaptureGeometry.windowPoint(
                CGPoint(x: 526, y: 336),
                pixelSize: size,
                bounds: bounds
            ))
        }
        for point in [
            CGPoint(x: -1, y: 2),
            CGPoint(x: CGFloat.nan, y: 2),
            CGPoint(x: 2, y: CGFloat.infinity),
            CGPoint(x: 1512, y: 0),
            CGPoint(x: 0, y: 876)
        ] {
            XCTAssertThrowsError(try WindowCaptureGeometry.windowPoint(point, pixelSize: bounds.size, bounds: bounds))
        }
        XCTAssertThrowsError(try WindowCaptureGeometry.windowPoint(.zero, pixelSize: bounds.size, bounds: nil))
    }

    func testCaptureUsesItsOwnDisplayScaleAndRejectsMovedOrClippedContent() {
        let bounds = CGRect(x: -1920, y: -1080, width: 1200, height: 800)
        for scale in [CGFloat(1), 1.25, 2] {
            XCTAssertEqual(WindowCaptureGeometry.fullWindowPixelSize(
                bounds: bounds, capturedFrame: bounds, contentSize: bounds.size, scale: scale
            ), CGSize(width: 1200 * scale, height: 800 * scale))
        }
        XCTAssertNil(WindowCaptureGeometry.fullWindowPixelSize(
            bounds: bounds, capturedFrame: bounds.offsetBy(dx: 1, dy: 0), contentSize: bounds.size, scale: 2
        ))
        XCTAssertNil(WindowCaptureGeometry.fullWindowPixelSize(
            bounds: bounds, capturedFrame: bounds, contentSize: CGSize(width: 600, height: 400), scale: 2
        ))
        for scale in [CGFloat.nan, .infinity, 0, -1] {
            XCTAssertNil(WindowCaptureGeometry.fullWindowPixelSize(
                bounds: bounds, capturedFrame: bounds, contentSize: bounds.size, scale: scale
            ))
        }
    }
}
