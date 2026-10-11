@testable import OpenComputerUseKit
import XCTest

final class NativeToolArgumentsTests: XCTestCase {
    private let app = "unobserved-parameter-test-app"

    func testUnknownFieldsFailForEveryNativeToolBeforeObservation() throws {
        let dispatcher = ComputerUseToolDispatcher()
        for definition in ToolDefinitions.all + [ToolDefinitions.hover] {
            let result = dispatcher.callToolAsResult(
                name: definition.name,
                arguments: ["modifiers": ["Command"], "private-user-content": "do-not-echo"]
            )
            let text = try XCTUnwrap(result.primaryText)
            XCTAssertTrue(result.isError, definition.name)
            XCTAssertTrue(text.contains("Unsupported options"), definition.name)
            XCTAssertTrue(text.contains("No input was sent"), definition.name)
            XCTAssertFalse(text.contains("private-user-content"))
            XCTAssertFalse(text.contains("do-not-echo"))
        }
    }

    func testModifierCannotDegradeToPlainSOnMCPTransport() throws {
        let server = StdioMCPServer(service: ComputerUseService())
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "press_key", "arguments": ["app": app, "key": "s", "modifiers": ["Command"]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        let reply = try XCTUnwrap(server.handle(line: line))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("super+s"))
        XCTAssertTrue(text.contains("Unsupported options"))
        XCTAssertFalse(text.contains("snapshot"))
    }

    func testInvalidOptionalTypesNeverBecomeDefaultClicksOrKeys() {
        let click: [String: Any] = ["app": app, "x": 1, "y": 2]
        for key in ["mouse_button", "click_method", "click_count", "x", "y", "element_index", "popup_token"] {
            for badValue: Any in [NSNull(), ["unexpected"], ["nested": 1], true] {
                assertInvalid("click", click.merging([key: badValue]) { _, new in new })
            }
        }
        for tool in ["press_key", "type_text"] {
            let base: [String: Any] = ["app": app, tool == "press_key" ? "key" : "text": "s"]
            for value: Any in [NSNull(), 1, true, ["auto"]] {
                assertInvalid(tool, base.merging(["key_method": value]) { _, new in new })
            }
        }
    }

    func testCLIBatchStopsAtInvalidArgumentsWithoutContinuing() throws {
        let calls = #"""
        [
          {"tool":"press_key","args":{"app":"unobserved","key":"s","modifiers":["Command"]}},
          {"tool":"list_apps","args":{}}
        ]
        """#
        var sleeps = 0
        let output = try runOpenComputerUseCall(
            .sequence(callsJSON: calls, callsFile: nil, interCallDelay: 0.5),
            sleepHandler: { _ in sleeps += 1 }
        )
        XCTAssertTrue(output.hasToolError)
        let results = try XCTUnwrap(output.jsonObject as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(sleeps, 0)
        XCTAssertTrue(try output.jsonText().contains("Unsupported options"))
    }

    func testNumbersRejectBooleansFractionsNonfiniteAndIntegerOverflow() throws {
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data("[true,1,1.5,9223372036854775808]".utf8)) as? [Any]
        )
        let values: [Any] = [true, NSNumber(value: false), 0, -1, 1.5, Double.nan, Double.infinity,
                             Double(Int.max), "2", NSNull(), decoded[0], decoded[2], decoded[3]]
        for value in values {
            assertInvalid("click", ["app": app, "x": 1, "y": 2, "click_count": value])
            assertInvalid("get_app_state", ["app": app, "max_tree_nodes": value])
        }
        for value: Any in [true, Double.nan, Double.infinity, "20"] {
            assertInvalid("drag", ["app": app, "from_x": value, "from_y": 0, "to_x": 10, "to_y": 10])
        }
        XCTAssertEqual(try nativeToolInteger(Int.max, key: "count"), Int.max)
        XCTAssertEqual(try nativeToolInteger(2.0, key: "count"), 2)
        XCTAssertNil(normalizedElementIndexArgument(NSNumber(value: true)))
    }

    func testSupportedOptionsKeepCompatibilityWithoutOperatingAnApp() throws {
        let cases: [(String, [String: Any])] = [
            ("click", ["app": app, "element_index": 0, "mouse_button": " RIGHT ", "click_method": " AUTO "]),
            ("click", ["app": app, "x": 0.5, "y": 2, "click_count": 2.0]),
            ("click", ["app": app, "popup_token": "test-token", "x": 1, "y": 2, "click_method": "global"]),
            ("press_key", ["app": app, "key": "super+s", "key_method": " SKY_KEY "]),
            ("type_text", ["app": app, "text": "中文"]),
            ("get_app_state", ["app": app, "text_limit": "MAX", "initialize": false]),
            ("get_app_state", ["app": app, "text_limit": 10, "max_tree_depth": 2]),
            ("hover", ["app": app, "observe_only": true]),
            ("hover", ["app": app, "element_index": 0, "duration_ms": 0]),
            ("list_apps", [:])
        ]
        for (name, arguments) in cases {
            XCTAssertNoThrow(try validateNativeToolArguments(name: name, arguments: arguments), name)
        }
    }

    func testAmbiguousOrIncompleteClickTargetIsRejected() {
        for target: [String: Any] in [[:], ["x": 1], ["y": 1], ["element_index": 0, "x": 1],
                                      ["element_index": 0, "x": 1, "y": 2]] {
            assertInvalid("click", target.merging(["app": app]) { _, new in new })
        }
    }

    func testHoverObservationConstantAndDurationBoundsRemainEnforced() {
        assertInvalid("hover", ["app": app, "observe_only": false])
        for duration in [-1, 2001] {
            assertInvalid("hover", ["app": app, "element_index": 0, "duration_ms": duration])
        }
    }

    func testInvalidEnumAndUnknownToolAreNotReinterpreted() {
        assertInvalid("press_key", ["app": app, "key": "s", "key_method": "invented"])
        assertInvalid("click", ["app": app, "element_index": 0, "mouse_button": "invented"])
        assertInvalid("click", ["app": app, "element_index": 0, "click_method": "invented"])
        XCTAssertThrowsError(try validateNativeToolArguments(name: "unknown", arguments: [:])) { error in
            guard case ComputerUseError.unsupportedTool = error else { return XCTFail("Wrong error") }
        }
    }

    private func assertInvalid(
        _ name: String,
        _ arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 没有建立任何 App 快照；若落到 service，会得到 stateUnavailable 而非参数错误。
        XCTAssertThrowsError(
            try ComputerUseToolDispatcher().callTool(name: name, arguments: arguments),
            file: file,
            line: line
        ) { error in
            guard case ComputerUseError.invalidArguments = error else {
                return XCTFail("Expected rejection before service, got \(error)", file: file, line: line)
            }
        }
    }
}
