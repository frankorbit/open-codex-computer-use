import ApplicationServices
import Foundation

/// 仅供侧栏预检使用；查询保留原 AXError，权限拒绝优先于事后 deadline／取消检查。
func readAXSidebarPreflight<Value>(
    remaining: () -> TimeInterval,
    checkDeadline: () throws -> Void,
    setTimeout: (Float) -> AXError,
    query: () throws -> (AXError, Value)
) throws -> (AXError, Value) {
    try checkDeadline()
    let budget = remaining()
    guard budget.isFinite, budget > 0 else {
        throw axInputPreflightFailure("sidebar validation timed out")
    }
    let timeout = Float(min(0.05, budget))
    guard timeout > 0 else {
        throw axInputPreflightFailure("sidebar validation timed out")
    }

    let configured = setTimeout(timeout)
    let outcome = Result<(AXError, Value), Error> {
        if configured == .apiDisabled { throw sidebarPreflightPermissionDenied() }
        guard configured == .success else {
            throw axInputPreflightFailure("sidebar timeout setup failed (AX \(configured.rawValue))")
        }
        try checkDeadline()
        let result = try query()
        if result.0 == .apiDisabled { throw sidebarPreflightPermissionDenied() }
        try checkDeadline()
        return result
    }

    // 即使设置或查询失败，也恢复默认超时；不能让短读取超时泄漏到后续输入。
    let restored = setTimeout(0)
    if restored == .apiDisabled { throw sidebarPreflightPermissionDenied() }
    let result = try outcome.get()
    guard restored == .success else {
        throw axInputPreflightFailure("sidebar timeout restore failed (AX \(restored.rawValue))")
    }
    try checkDeadline()
    return result
}

private func sidebarPreflightPermissionDenied() -> ComputerUseError {
    .permissionDenied(
        "Accessibility permission is required (AX \(AXError.apiDisabled.rawValue)); "
            + "no further input was sent; do not replay the previous action"
    )
}
