import Foundation

/// 阶段只标记已经进入的操作；进入投递后不能断言事件未发出。
enum ForegroundClickStage: String {
    case policy
    case targetValidation = "target_validation"
    case activation
    case receiverValidation = "receiver_validation"
    case submission
}

struct ForegroundClickFailure: Error, LocalizedError {
    let stage: ForegroundClickStage
    let cause: Cause

    /// 只保留错误类别，不转发关联字符串、NSError domain 或第三方错误正文。
    enum Cause: String {
        case invalidArguments = "invalid_arguments"
        case permissionDenied = "permission_denied"
        case stateUnavailable = "state_unavailable"
        case appNotFound = "app_not_found"
        case unsupportedTool = "unsupported_tool"
        case operationFailed = "operation_failed"
        case unexpectedError = "unexpected_error"

        init(_ error: Error) {
            guard let error = error as? ComputerUseError else {
                self = .unexpectedError
                return
            }
            switch error {
            case .invalidArguments: self = .invalidArguments
            case .permissionDenied: self = .permissionDenied
            case .stateUnavailable: self = .stateUnavailable
            case .appNotFound: self = .appNotFound
            case .unsupportedTool: self = .unsupportedTool
            case .message: self = .operationFailed
            }
        }
    }

    var inputMayHaveOccurred: Bool {
        stage == .submission
    }

    var activationMayHaveOccurred: Bool {
        stage != .policy && stage != .targetValidation
    }

    var diagnosticFields: [String: String] {
        [
            "stage": stage.rawValue,
            "code": "foreground_click_\(stage.rawValue)_failed",
            "cause": cause.rawValue,
            "input_may_have_occurred": String(inputMayHaveOccurred),
            "activation_may_have_occurred": String(activationMayHaveOccurred)
        ]
    }

    var errorDescription: String? {
        let fields = diagnosticFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let effect = inputMayHaveOccurred
            ? "Input may have occurred; UI effect is unknown."
            : "No HID mouse input was sent by this call."
        return "Foreground click failed: \(fields). \(effect) "
            + "Observe the target before further input; do not replay automatically."
    }
}

func performForegroundClickStage(
    _ stage: ForegroundClickStage,
    authorization: ForegroundClickAuthorization?,
    body: () throws -> Void
) throws {
    do {
        try body()
    } catch {
        // 普通 global 路径沿用原始错误契约；只有单次入口增加脱敏诊断。
        guard authorization != nil else { throw error }
        let failure = ForegroundClickFailure(stage: stage, cause: .init(error))
        InputDiagnostics.event("foreground_click_failed", failure.diagnosticFields)
        throw failure
    }
}
