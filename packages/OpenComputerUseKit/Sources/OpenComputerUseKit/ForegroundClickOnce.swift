import Foundation

/// 资格只来自最近一次显式观察；任意后续请求都会消费，不能跨目标或重复使用。
struct ForegroundClickObservation {
    let app: String
    let observedAt: TimeInterval

    func validate(app: String, now: TimeInterval) throws {
        guard self.app == app, now >= observedAt, now - observedAt <= 30 else {
            throw ComputerUseError.stateUnavailable(
                "Foreground click requires get_app_state for this exact app within 30 seconds; no input was sent."
            )
        }
    }
}

/// 仅宿主启用的单次入口创建；不改变进程执行策略，也不授权其他输入类型。
enum ForegroundClickAuthorization {
    case hostSingleClick
}

extension ToolDefinitions {
    public static let foregroundClickOnce = ToolDefinition(
        name: "click_foreground_once",
        description: "Single left HID click for an observed UI-opening control unresponsive to background input. "
            + "May activate the window and move the real pointer. Requires host capability and a preceding "
            + "get_app_state within 30 seconds. Consumes that observation even on failure; never automatically replay "
            + "or use for send/submit/delete retries. Observe after the call.",
        annotations: ["destructiveHint": false, "openWorldHint": false],
        inputSchema: [
            "type": "object", "additionalProperties": false,
            "required": ["app", "x", "y", "purpose"],
            "properties": [
                "app": ["type": "string"],
                "x": ["type": "number"], "y": ["type": "number"],
                "purpose": ["type": "string", "enum": ["open_control"]]
            ]
        ]
    )
}
