import CoreGraphics
import Foundation

/// AX 已明确为空后，排除 WindowServer 保留但未显示、未归属任何 Space 的辅助记录。
struct OpeningWindowAbsence {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var spaces: (CGWindowID) -> [UInt64]? = { SkyLightSPI.shared.spaces(forWindow: $0) }
    var checkCancellation: () throws -> Void = { try Task.checkCancellation() }

    func isConfirmed(
        appPID: pid_t, axWindowCount: Int?, windowInfo: [[String: Any]]?, deadline: TimeInterval
    ) throws -> Bool {
        try checkCancellation()
        guard now() < deadline, axWindowCount == 0, let windowInfo else { return false }
        for info in windowInfo {
            try checkCancellation()
            guard now() < deadline else { return false }
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            guard owner == appPID else { continue }
            // CG 对已移出屏幕的记录省略 IsOnscreen；异常类型不能当作不可见。
            if let visible = info[kCGWindowIsOnscreen as String] {
                guard let onScreen = visible as? Bool, !onScreen else { return false }
            }
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let windowID = CGWindowID(exactly: number.doubleValue), windowID != 0,
                  let assignedSpaces = spaces(windowID), assignedSpaces.isEmpty else { return false }
            // 非当前 Space、最小化及未知归属都保留为窗口；迟到结果也不能触发 reopen。
            try checkCancellation()
            guard now() < deadline else { return false }
        }
        return true
    }
}
