import AppKit
@testable import OpenComputerUseKit
import XCTest

final class AXPressReadBackTests: XCTestCase {
    private var saved: [String: String] = [:]
    private let keys = [
        "OPEN_COMPUTER_USE_ACTION_READ_BACK",
        "OPEN_COMPUTER_USE_VISUAL_CURSOR",
        "OPEN_COMPUTER_USE_LIVE_PREVIEW"
    ]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "0", 1)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { setenv(key, value, 1) } else { unsetenv(key) }
        }
        super.tearDown()
    }

    private static func snapshot(text: String, window: CGWindowID = 10) -> AppSnapshot {
        let app = RunningAppDescriptor(
            name: "Test",
            bundleIdentifier: "test.failed-press",
            pid: getpid(),
            runningApplication: .current
        )
        let record = ElementRecord(
            index: 39, identifier: nil, element: AXUIElementCreateApplication(-1),
            localFrame: CGRect(x: 10, y: 10, width: 60, height: 20), role: kAXButtonRole,
            rawActions: ["AXPress", "AXConfirm"], prettyActions: []
        )
        return AppSnapshot(
            app: app, windowTitle: nil, windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetWindowID: window, targetWindowLayer: 0, screenshotData: Data([1, 2, 3]), mode: .accessibility,
            treeLines: [text], focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
            elements: [39: record]
        )
    }

    private static func call(_ service: ComputerUseService) throws -> [String: Any] {
        let line = #"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call",
        "params":{"name":"click","arguments":{"app":"test.failed-press","element_index":39}}}
        """#
        let server = StdioMCPServer(service: service)
        let data = try XCTUnwrap(server.handle(line: line)?.data(using: .utf8))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    func testFailedPressKeepsErrorWithChangedOrUnchangedObservationAndInvalidatesInput() throws {
        for text in ["popover Title: Test Date: off", "original unchanged"] {
            let initial = Self.snapshot(text: "original"), fresh = Self.snapshot(text: text)
            var inputs = 0, reads = 0
            let service = ComputerUseService(snapshots: ["test.failed-press": initial], snapshotDependencies: .init(
                resolve: { _ in XCTFail("No resolve/reopen")
                    return initial.app
                },
                build: { _, _, _, policy, _ in reads += 1
                    XCTAssertEqual(policy, .readOnly)
                    return fresh
                },
                processIdentity: popupTestProcessIdentity, bindingIdentity: popupTestBindingIdentity,
                captureHoverPopups: { _, _ in XCTFail("No popup tokens")
                    return .incomplete
                }
            ), axActionBackend: { _, _ in inputs += 1
                return .failure
            })
            let result = try Self.call(service)
            XCTAssertEqual(result["isError"] as? Bool, true)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let output = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertTrue(output.contains("returned -25200"))
            XCTAssertTrue(output.contains("effect is unknown"))
            XCTAssertTrue(output.contains(text))
            XCTAssertTrue(content.contains { $0["type"] as? String == "image" })
            XCTAssertEqual(inputs, 1)
            XCTAssertEqual(reads, 1)
            XCTAssertThrowsError(try service.click(
                app: "test.failed-press",
                elementIndex: "39",
                x: nil,
                y: nil,
                clickCount: 1,
                mouseButton: "left"
            ))
            XCTAssertEqual(inputs, 1)
        }
    }

    func testReadBackFailureOrChangedWindowCannotReplaceOriginalErrorOrExposeUnboundContent() throws {
        for changedWindow in [false, true] {
            let initial = Self.snapshot(text: "original"), changed = Self.snapshot(text: "must not leak", window: 11)
            var inputs = 0, reads = 0
            let service = ComputerUseService(snapshots: ["test.failed-press": initial], snapshotDependencies: .init(
                resolve: { _ in initial.app }, build: { _, _, _, _, _ in
                    reads += 1
                    if changedWindow { return changed }
                    throw ComputerUseError.permissionDenied("permission revoked")
                }, processIdentity: popupTestProcessIdentity, bindingIdentity: popupTestBindingIdentity
            ), axActionBackend: { _, _ in inputs += 1
                return .failure
            })
            let result = try Self.call(service)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertTrue(text.contains("returned -25200"))
            XCTAssertTrue(text.contains("Post-error observation failed"))
            XCTAssertFalse(text.contains("must not leak"))
            XCTAssertFalse(content.contains { $0["type"] as? String == "image" })
            XCTAssertEqual(inputs, 1)
            XCTAssertEqual(reads, 1)
        }
    }

    func testPermissionTimeoutAndOtherAXErrorsNeverStartReadBack() throws {
        for error: AXError in [.apiDisabled, .cannotComplete, .actionUnsupported, .invalidUIElement] {
            let initial = Self.snapshot(text: "original")
            var inputs = 0
            let service = ComputerUseService(snapshots: ["test.failed-press": initial], snapshotDependencies: .init(
                resolve: { _ in initial.app }, build: { _, _, _, _, _ in XCTFail("No recovery")
                    return initial
                }
            ), axActionBackend: { _, _ in inputs += 1
                return error
            })
            let result = try Self.call(service)
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertEqual(inputs, 1)
        }
    }

    func testCancelledTaskAndChangedProcessSkipReadBack() async throws {
        for cancelled in [false, true] {
            let task = Task {
                let initial = Self.snapshot(text: "original")
                let service = ComputerUseService(snapshots: ["test.failed-press": initial], snapshotDependencies: .init(
                    resolve: { _ in initial.app }, build: { _, _, _, _, _ in XCTFail("No recovery")
                        return initial
                    },
                    processIdentity: { pid in cancelled ? popupTestProcessIdentity(for: pid) : nil },
                    bindingIdentity: popupTestBindingIdentity
                ), axActionBackend: { _, _ in
                    if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                    return .failure
                })
                return try JSONSerialization.data(withJSONObject: Self.call(service))
            }
            let data = try await task.value
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertTrue(content.compactMap { $0["text"] as? String }.joined().contains("returned -25200"))
            XCTAssertFalse(content.contains { $0["type"] as? String == "image" })
        }
    }

    func testSuccessfulClickDoesNotGainErrorReadBack() throws {
        let initial = Self.snapshot(text: "original")
        var inputs = 0
        let service = ComputerUseService(snapshots: ["test.failed-press": initial], snapshotDependencies: .init(
            resolve: { _ in initial.app }, build: { _, _, _, _, _ in XCTFail("Readback disabled")
                return initial
            }
        ), axActionBackend: { _, _ in inputs += 1
            return .success
        })
        XCTAssertEqual(try Self.call(service)["isError"] as? Bool, false)
        XCTAssertEqual(inputs, 1)
    }
}
