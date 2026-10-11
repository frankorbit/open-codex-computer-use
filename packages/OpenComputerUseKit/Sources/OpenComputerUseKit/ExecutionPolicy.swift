import Foundation

/// 未设置时保持旧宿主行为；配置错误不得默认为兼容模式。
enum ExecutionPolicy: Equatable {
    case compatible
    case background

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let raw = environment["OPEN_COMPUTER_USE_EXECUTION_MODE"] else { return .compatible }
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "background" else {
            throw ComputerUseError.invalidArguments("Unknown OPEN_COMPUTER_USE_EXECUTION_MODE; input is disabled.")
        }
        return .background
    }

    var isBackground: Bool {
        self == .background
    }

    func requireForeground(_ operation: String) throws {
        guard !isBackground else {
            throw ComputerUseError
                .stateUnavailable("\(operation) is disabled by background execution mode; no input was sent.")
        }
    }

    func requireAXAction(_ action: String) throws {
        if ["axraise", "raise"].contains(action.lowercased()) {
            try requireForeground("AXRaise")
        }
    }
}

/// 只门控显式激活恢复，不影响 AX 焦点读取或 SkyLight 后台窗口准备。
func performWindowRecovery(
    policy: ExecutionPolicy,
    requested: SnapshotRecoveryPolicy,
    recover: () -> Bool
) -> Bool {
    guard !policy.isBackground, requested == .allowActivation else { return false }
    return recover()
}

/// postToPid 没有窗口定向保证；严格模式须在发送前确认实际接收窗口。
func dispatchAppPostInput(
    policy: ExecutionPolicy,
    validateReceiver: () throws -> Void,
    submit: () throws -> Void
) throws {
    if policy.isBackground { try validateReceiver() }
    try submit()
}
