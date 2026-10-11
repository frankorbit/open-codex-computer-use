import AppKit
import CoreGraphics
import Foundation
import OSLog

/// 诊断独立于 stdout/stderr；只接收调用点构造的标量，不接收请求正文或错误描述。
enum InputDiagnostics {
    @TaskLocal static var operationID: String?
    @TaskLocal static var observer: (@Sendable (String) -> Void)?
    private static let logger = Logger(subsystem: "ai.today.ocu", category: "input")

    static func event(_ event: String, _ fields: [String: String] = [:]) {
        guard let id = operationID, let text = encodedEvent(id: id, event: event, fields: fields) else { return }
        logger.notice("\(text, privacy: .public)")
        observer?(text)
    }

    static func encodedEvent(id: String, event: String, fields: [String: String]) -> String? {
        var record = fields
        record["diagnostic_id"] = id
        record["event"] = event
        record["helper_pid"] = String(ProcessInfo.processInfo.processIdentifier)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func desktopState(_ phase: String) {
        var fields = ["phase": phase]
        fields["foreground_pid"] = NSWorkspace.shared.frontmostApplication.map { String($0.processIdentifier) } ?? "unknown"
        fields["pointer"] = point(CGEvent(source: nil)?.location)
        event("desktop_state", fields)
    }

    static func point(_ point: CGPoint?) -> String {
        guard let point else { return "unknown" }
        return "\(point.x),\(point.y)"
    }

    static func bounds(_ bounds: CGRect?) -> String {
        guard let bounds else { return "unknown" }
        return "\(bounds.minX),\(bounds.minY),\(bounds.width),\(bounds.height)"
    }

    static func input(route: ClickMethod, point: CGPoint, _ body: () throws -> Void) throws {
        event("input_attempt", ["route": route.rawValue, "event_point": self.point(point)])
        do {
            try body()
            event("input_returned", ["route": route.rawValue, "effect": "unverified"])
        } catch {
            event("input_failed", ["route": route.rawValue, "effect": "unknown"])
            throw error
        }
    }

    static func result(tool: String = "click", _ body: () throws -> ToolCallResult) -> [String: Any] {
        let id = UUID().uuidString
        return $operationID.withValue(id) {
            let start = ProcessInfo.processInfo.systemUptime
            event("\(tool)_started")
            desktopState("tool_begin")
            let result: ToolCallResult
            do {
                result = try body()
            } catch let error as ComputerUseError {
                result = .text(error.errorDescription ?? "Computer Use failed", isError: error.toolResultIsError)
            } catch {
                result = .text((error as? LocalizedError)?.errorDescription ?? String(describing: error), isError: true)
            }
            desktopState("tool_end")
            var output = result.asDictionary
            let status = output["isError"] as? Bool == true ? "failed" : "returned"
            // returned 只表示函数返回；不能把它当作目标 App 已消费事件的证据。
            let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
            event("\(tool)_finished", ["status": status, "duration_ms": String(duration)])
            var metadata = output["_meta"] as? [String: Any] ?? [:]
            metadata["ocuDiagnostic"] = ["id": id, "tool": tool, "status": status]
            output["_meta"] = metadata
            return output
        }
    }
}
