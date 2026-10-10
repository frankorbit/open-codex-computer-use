import CoreGraphics
import Foundation

func validateCoordinateWindow(
    windowID: CGWindowID,
    pid: pid_t,
    bounds: CGRect,
    point: CGPoint,
    windows: [[String: Any]],
    requireUnoccludedPoint: Bool,
    spacesForWindow: (CGWindowID) -> [UInt64]?
) throws {
    guard point.x.isFinite, point.y.isFinite, bounds.width > 0, bounds.height > 0, bounds.contains(point),
          let index = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }) else {
        throw ComputerUseError.stateUnavailable("Coordinate target is missing or outside its snapshot window; observe again")
    }
    let current = windows[index]
    guard (current[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          let currentBounds = coordinateWindowBounds(current), currentBounds == bounds,
          (current[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else {
        throw ComputerUseError.stateUnavailable("Coordinate target window changed owner, geometry or visibility; observe again")
    }

    if requireUnoccludedPoint && (current[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != true {
        throw ComputerUseError.stateUnavailable("Global pointer input requires an on-screen target window")
    }

    // WindowServer 按前后顺序返回窗口。同 App 弹窗不能绕过；窗口定向输入允许其他 App 覆盖。
    // 全局输入必须额外确认点击点未被其他 App 遮挡。忽略 helper 自己绘制的软件指针。
    for above in windows[..<index] {
        guard let owner = above[kCGWindowOwnerPID as String] as? NSNumber else {
            throw ComputerUseError.stateUnavailable("Cannot verify a window above the coordinate target")
        }
        if owner.int32Value == getpid() { continue }
        if !requireUnoccludedPoint && owner.int32Value != pid { continue }
        guard (above[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              (above[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }
        guard let aboveBounds = coordinateWindowBounds(above) else {
            throw ComputerUseError.stateUnavailable("Cannot verify bounds of a window above the coordinate target")
        }
        guard aboveBounds.contains(point) else { continue }
        // 不同 Space 可以有完全相同的坐标，不能据此认定互相遮挡。
        guard let aboveID = (above[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let targetSpaces = spacesForWindow(windowID), !targetSpaces.isEmpty,
              let aboveSpaces = spacesForWindow(aboveID), !aboveSpaces.isEmpty else {
            throw ComputerUseError.stateUnavailable("Cannot verify Spaces of overlapping windows; observe again")
        }
        if !Set(targetSpaces).isDisjoint(with: aboveSpaces) {
            throw ComputerUseError.stateUnavailable("Coordinate target is covered by another receiving window; observe again")
        }
    }
}

private func coordinateWindowBounds(_ info: [String: Any]) -> CGRect? {
    guard let value = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: value as CFDictionary)
}

func validateCoordinateAppPostReceiver(frontmostPID: pid_t?, expectedPID: pid_t, focusedWindowMatches: Bool) throws {
    // app_post 只有 PID，没有窗口 ID；不能套用 sky_click 的后台和跨 Space 豁免。
    guard frontmostPID == expectedPID, focusedWindowMatches else {
        throw ComputerUseError.stateUnavailable("auto app_post requires the foreground app and focused snapshot window; observe again")
    }
}
