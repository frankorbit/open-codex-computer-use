import AppKit
import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class FinderSidebarClickServiceTests: XCTestCase {
    private var previousEnvironment: [String: String] = [:]
    private let keys = ["OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_VISUAL_CURSOR"]

    override func setUp() {
        super.setUp()
        for key in keys {
            previousEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "0", 1)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = previousEnvironment[key] { setenv(key, value, 1) } else { unsetenv(key) }
        }
        super.tearDown()
    }

    private func state() throws -> AppSnapshot {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let app = RunningAppDescriptor(
            name: "Finder", bundleIdentifier: "com.apple.finder", pid: getpid(), runningApplication: .current
        )
        // 无效 AX 对象不能发送真实 GUI 输入；若选择路径错误落入 Open，入口必须报错。
        let row = ElementRecord(
            index: 8, identifier: nil, element: AXUIElementCreateApplication(-1),
            localFrame: CGRect(x: 10, y: 10, width: 60, height: 20), role: kAXRowRole,
            rawActions: ["AXOpen"], prettyActions: []
        )
        return AppSnapshot(
            app: app, windowTitle: nil, windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetWindowID: nil, targetWindowLayer: nil, screenshotData: png, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: [8: row]
        )
    }

    func testActualClickEntryEndsAfterSidebarSelectionWithoutOpen() throws {
        for method in [ClickMethod.auto, .accessibility] {
            var sends = 0
            let snapshot = try state()
            let service = ComputerUseService(
                snapshots: ["com.apple.finder": snapshot], snapshotDependencies: .live,
                sidebarSelectionBackend: { _, observed in
                    XCTAssertEqual(observed.app.bundleIdentifier, "com.apple.finder")
                    sends += 1
                    return true
                }
            )
            _ = try service.click(
                app: "com.apple.finder", elementIndex: "8", x: nil, y: nil,
                clickCount: 1, mouseButton: "left", clickMethod: method
            )
            XCTAssertEqual(sends, 1)
        }
    }

    func testActualClickEntryPreservesSelectionFailureWithoutOpenOrReplay() throws {
        for method in [ClickMethod.auto, .accessibility] {
            var sends = 0
            let service = try ComputerUseService(
                snapshots: ["com.apple.finder": state()], snapshotDependencies: .live,
                sidebarSelectionBackend: { _, _ in
                    sends += 1
                    throw ComputerUseError.message("selection attempted; test stop")
                }
            )
            XCTAssertThrowsError(try service.click(
                app: "com.apple.finder", elementIndex: "8", x: nil, y: nil,
                clickCount: 1, mouseButton: "left", clickMethod: method
            )) { error in
                XCTAssertTrue(String(describing: error).contains("selection attempted; test stop"))
            }
            XCTAssertEqual(sends, 1)
        }
    }
}
