import ApplicationServices
import Foundation

enum AXActionExecutionResult: Equatable {
    /// 只有调用前确认未声明动作，才允许继续尝试其他候选。
    case notAttempted
    /// 仅表示所有 AX 调用返回 success，实际界面效果仍需观察。
    case completed
}

/// 只记录白名单元数据；不得写入自定义动作、控件标签或应用内容。
struct AXActionDiagnosticContext {
    enum Route: String, CaseIterable {
        case action = "ax_action"
        case secondary = "ax_secondary"
    }

    enum Source: String, CaseIterable {
        case original
        case descendant
        case hit
        case hitDescendant = "hit_descendant"
        case containingWebRow = "containing_web_row"
    }

    var route: Route = .action
    var source: Source = .original
    var role: String?
    var originalIndex: Int?

    func perform(action: String, attempt: Int, _ body: () -> AXError) -> AXError {
        let actionName = switch action.lowercased() {
        case "axpress": "press"
        case "axconfirm": "confirm"
        case "axopen": "open"
        case "axshowmenu": "show_menu"
        case "axraise": "raise"
        default: "other"
        }
        let knownRoles: Set = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSwitch",
            "AXMenuItem", "AXMenu", "AXMenuBarItem", "AXWindow", "AXRow", "AXCell", "AXGroup",
            "AXList", "AXOutline", "AXTable", "AXTextField", "AXTextArea", "AXStaticText", "AXLink", "AXWebArea"
        ]
        var fields = [
            "route": route.rawValue, "action": actionName, "source": source.rawValue,
            "role": role.map { knownRoles.contains($0) ? $0 : "other" } ?? "unknown",
            "attempt": String(attempt)
        ]
        if let originalIndex, originalIndex >= 0 { fields["original_index"] = String(originalIndex) }
        InputDiagnostics.event("input_attempt", fields)
        let result = body()
        fields["ax_result"] = String(result.rawValue)
        fields["effect"] = result == .success ? "unverified" : "unknown"
        InputDiagnostics.event("input_returned", fields)
        return result
    }
}

/// Observation gives each element a 0.05–0.1 s messaging timeout so tree reads stay
/// fast, and input reuses those elements. Opening or closing a modal sheet, or saving,
/// often takes longer to answer, so a short timeout turned an action that already took
/// effect into `cannotComplete` ("effect is unknown"). Input first gives the element a
/// longer timeout so the result reflects the action; a real timeout is still unknown.
let axInputMessagingTimeout: Float = 2

func prepareAXInput(
    _ element: AXUIElement,
    setTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout
) {
    _ = setTimeout(element, axInputMessagingTimeout)
}

func executeAXAction(
    named action: String,
    availableActions: [String],
    repeatCount: Int = 1,
    preflight: () throws -> Void = {},
    prepare: () -> Void = {},
    diagnostics: AXActionDiagnosticContext = .init(),
    perform: () -> AXError,
    pauseBetweenAttempts: () -> Void = { Thread.sleep(forTimeInterval: 0.05) }
) throws -> AXActionExecutionResult {
    try ExecutionPolicy.current().requireAXAction(action)
    guard availableActions.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) else {
        return .notAttempted
    }
    try preflight()
    prepare()

    let attempts = max(repeatCount, 1)
    for index in 0 ..< attempts {
        let result = diagnostics.perform(action: action, attempt: index + 1, perform)
        // 调用已发出；即使返回 unsupported，也不能证明零副作用或重放已成功的前几次。
        guard result == .success else {
            let message = "AXUIElementPerformAction(\(action)) returned \(result.rawValue) "
                + "on attempt \(index + 1)/\(attempts) "
                + "after \(index) successful AX returns; effect is unknown. "
                + "Observe before further input; no further AX candidate or mouse fallback was sent."
            if result == .failure, action == kAXPressAction as String, attempts == 1,
               diagnostics.source == .original, diagnostics.role == kAXButtonRole as String {
                throw AXPressFailure(message: message)
            }
            throw ComputerUseError.message(message)
        }
        if index < attempts - 1 {
            pauseBetweenAttempts()
        }
    }
    return .completed
}
