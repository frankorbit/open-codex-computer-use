import ApplicationServices
import Foundation

enum AXActionExecutionResult: Equatable {
    /// 只有调用前确认未声明动作，才允许继续尝试其他候选。
    case notAttempted
    /// 仅表示所有 AX 调用返回 success，实际界面效果仍需观察。
    case completed
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
        let result = perform()
        // 调用已发出；即使返回 unsupported，也不能证明零副作用或重放已成功的前几次。
        guard result == .success else {
            throw ComputerUseError.message(
                "AXUIElementPerformAction(\(action)) returned \(result.rawValue) on attempt \(index + 1)/\(attempts) "
                    + "after \(index) successful AX returns; effect is unknown. "
                    + "Observe before further input; no further AX candidate or mouse fallback was sent."
            )
        }
        if index < attempts - 1 {
            pauseBetweenAttempts()
        }
    }
    return .completed
}
