import CoreGraphics
import Foundation

enum CoordinateWindowObstructions {
    case onScreenAbove([[String: Any]])
    case onScreenWithoutRelativeOrder([[String: Any]])

    var windows: [[String: Any]] {
        switch self {
        case let .onScreenAbove(windows), let .onScreenWithoutRelativeOrder(windows): windows
        }
    }

    var hasRelativeOrder: Bool {
        if case .onScreenAbove = self { return true }
        return false
    }
}

/// 仅供后台输入惰性调用；完整窗口集合只提供身份，不提供 Z 序。
func coordinateWindowObstructions(
    windowID: CGWindowID,
    pid: pid_t,
    bounds: CGRect,
    point: CGPoint,
    isOnScreen: Bool,
    query: (CGWindowListOption, CGWindowID) -> [[String: Any]]? = {
        CGWindowListCopyWindowInfo($0, $1) as? [[String: Any]]
    }
) throws -> CoordinateWindowObstructions {
    let candidates: [[String: Any]]
    let target: [[String: Any]]
    if isOnScreen {
        guard let above = query([.optionOnScreenAboveWindow, .optionIncludingWindow], windowID) else {
            throw ComputerUseError.stateUnavailable("Cannot query windows above the coordinate target; observe again")
        }
        candidates = above.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value != windowID }
        target = above
    } else {
        // above 对非屏上目标不足以证明无遮挡；仅检查可见候选是否属于同一 Space。
        guard let onScreen = query(.optionOnScreenOnly, kCGNullWindowID),
              let current = query(.optionIncludingWindow, windowID)
        else {
            throw ComputerUseError
                .stateUnavailable("Cannot query windows around the off-screen coordinate target; observe again")
        }
        guard !onScreen.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else {
            throw ComputerUseError
                .stateUnavailable("Coordinate target visibility changed during validation; observe again")
        }
        candidates = onScreen
        target = current
    }
    // 查询层级后重验身份和几何；不能把销毁、换 PID 或可见性变化当作空遮挡集合。
    try validateCoordinateWindow(
        windowID: windowID, pid: pid, bounds: bounds, point: point,
        windows: target, requireUnoccludedPoint: false, identityOnly: true, spacesForWindow: { _ in nil }
    )
    let current = target.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
    guard ((current?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true) == isOnScreen else {
        throw ComputerUseError.stateUnavailable("Coordinate target visibility changed during validation; observe again")
    }
    return isOnScreen ? .onScreenAbove(candidates) : .onScreenWithoutRelativeOrder(candidates)
}
