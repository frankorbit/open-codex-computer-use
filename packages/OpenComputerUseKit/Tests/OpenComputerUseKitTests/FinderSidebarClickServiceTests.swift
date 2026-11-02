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

    private func state(
        bundleIdentifier: String = "com.apple.finder", panelRole: String? = nil,
        panelIdentifier: String? = nil, rowRole: String = kAXRowRole
    ) throws -> AppSnapshot {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let app = RunningAppDescriptor(
            name: "Test", bundleIdentifier: bundleIdentifier, pid: getpid(), runningApplication: .current
        )
        // 无效 AX 对象不能发送真实 GUI 输入；若选择路径错误落入 Open，入口必须报错。
        let row = ElementRecord(
            index: 8, identifier: nil, element: AXUIElementCreateApplication(-1),
            localFrame: CGRect(x: 10, y: 10, width: 60, height: 20), role: rowRole,
            rawActions: ["AXOpen"], prettyActions: []
        )
        var elements = [8: row]
        if let panelRole {
            elements[0] = ElementRecord(
                index: 0, identifier: panelIdentifier, element: AXUIElementCreateApplication(-2),
                localFrame: CGRect(x: 0, y: 0, width: 100, height: 100), role: panelRole,
                rawActions: [], prettyActions: []
            )
        }
        return AppSnapshot(
            app: app, windowTitle: nil, windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetWindowID: nil, targetWindowLayer: nil, screenshotData: png, mode: .accessibility,
            treeLines: [], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: elements
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

extension FinderSidebarClickServiceTests {
    func testFilePanelActualClickEntrySelectsOnceAndStopsOnError() throws {
        for method in [ClickMethod.auto, .accessibility] {
            for panel in [("AXSheet", "save-panel"), ("AXWindow", "open-panel")] {
                for fails in [false, true] {
                    var sends = 0
                    let snapshot = try state(
                        bundleIdentifier: "com.apple.TextEdit", panelRole: panel.0, panelIdentifier: panel.1
                    )
                    let service = ComputerUseService(
                        snapshots: ["com.apple.TextEdit": snapshot], snapshotDependencies: .live,
                        sidebarSelectionBackend: { _, _ in
                            sends += 1
                            if fails { throw ComputerUseError.message("selection attempted; test stop") }
                            return true
                        }
                    )
                    let operation = {
                        try service.click(app: "com.apple.TextEdit", elementIndex: "8", x: nil, y: nil,
                                          clickCount: 1, mouseButton: "left", clickMethod: method)
                    }
                    if fails {
                        XCTAssertThrowsError(try operation()) { error in
                            XCTAssertTrue(error.localizedDescription.contains("selection attempted; test stop"))
                        }
                    } else { _ = try operation() }
                    XCTAssertEqual(sends, 1)
                }
            }
        }
    }

    func testNonPanelAndNonSingleRowClicksDoNotEnterNewRoute() throws {
        struct Case {
            let panelRole: String?
            let identifier: String?
            let rowRole: String
            let count: Int
            let button: String

            init(_ role: String?, _ identifier: String?, _ row: String, _ count: Int, _ button: String) {
                panelRole = role
                self.identifier = identifier
                rowRole = row
                self.count = count
                self.button = button
            }
        }
        let cases: [Case] = [
            .init(nil, nil, "AXRow", 1, "left"),
            .init("AXWindow", "document", "AXRow", 1, "left"),
            .init("AXGroup", "save-panel", "AXRow", 1, "left"),
            .init("AXSheet", "save-panel", "AXCell", 1, "left"),
            .init("AXSheet", "save-panel", "AXTextField", 1, "left"),
            .init("AXSheet", "save-panel", "AXRow", 2, "left"),
            .init("AXSheet", "save-panel", "AXRow", 1, "right")
        ]
        for testCase in cases {
            var selections = 0
            let snapshot = try state(bundleIdentifier: "com.apple.TextEdit", panelRole: testCase.panelRole,
                                     panelIdentifier: testCase.identifier, rowRole: testCase.rowRole)
            let service = ComputerUseService(
                snapshots: ["com.apple.TextEdit": snapshot], snapshotDependencies: .live,
                sidebarSelectionBackend: { _, _ in selections += 1; return true }
            )
            // 无效句柄使原有路径安全失败；不能实际发送 GUI 输入。
            XCTAssertThrowsError(try service.click(
                app: "com.apple.TextEdit", elementIndex: "8", x: nil, y: nil,
                clickCount: testCase.count, mouseButton: testCase.button, clickMethod: .accessibility
            ))
            XCTAssertEqual(selections, 0)
        }
    }
}
