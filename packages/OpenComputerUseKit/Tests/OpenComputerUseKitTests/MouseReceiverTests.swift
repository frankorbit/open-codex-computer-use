import CoreGraphics
@testable import OpenComputerUseKit
import XCTest

final class MouseReceiverTests: XCTestCase {
    func testQuartzCoordinatesConvertToAppKitOnPrimaryAndSecondaryDisplays() {
        let mappings = [
            VisualCursorScreenMapping(screenStateFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            VisualCursorScreenMapping(screenStateFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                      appKitFrame: CGRect(x: -1920, y: 102, width: 1920, height: 1080))
        ]
        let samples = [(CGPoint(x: 536, y: 471), CGPoint(x: 536, y: 511)),
                       (CGPoint(x: -600, y: 400), CGPoint(x: -600, y: 582))]
        for (point, expected) in samples {
            let result = mouseReceiverWindow(at: point, screenMappings: mappings) {
                XCTAssertEqual($0, expected)
                return 42
            }
            XCTAssertEqual(result, 42)
        }
    }

    func testMissingDisplayAndInvalidPointNeverQueryAppKit() {
        for point in [CGPoint(x: 10, y: 10), CGPoint(x: CGFloat.nan, y: 0)] {
            XCTAssertNil(mouseReceiverWindow(at: point, screenMappings: []) { _ in
                XCTFail("unmapped coordinates must not be queried")
                return 42
            })
        }
    }

    func testMissingOrInvalidWindowNumberIsUnknown() {
        let mapping = VisualCursorScreenMapping(screenStateFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        for number in [0, -1, Int(UInt32.max) + 1] {
            XCTAssertNil(mouseReceiverWindow(at: CGPoint(x: 20, y: 20), screenMappings: [mapping]) { _ in number })
        }
    }
}
