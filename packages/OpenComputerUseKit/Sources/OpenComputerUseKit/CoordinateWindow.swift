import CoreGraphics
import Foundation

func validateCoordinateWindow(
    windowID: CGWindowID,
    pid: pid_t,
    bounds: CGRect,
    point: CGPoint,
    windows: [[String: Any]],
    requireUnoccludedPoint: Bool,
    identityOnly: Bool = false,
    spacesForWindow: (CGWindowID) -> [UInt64]?,
    mouseReceiver: (CGPoint) -> CGWindowID? = { _ in nil }
) throws {
    var accepted = false
    defer { InputDiagnostics.event("window_validation", ["accepted": String(accepted), "window_id": String(windowID), "target_pid": String(pid), "require_unoccluded": String(requireUnoccludedPoint)]) }
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

    // 前台点击的激活前阶段只核对身份与几何；遮挡必须在精确窗口激活后再核对。
    if identityOnly {
        accepted = true
        return
    }

    if requireUnoccludedPoint {
        // 矩形重叠不代表会接收输入；AppKit 命中测试会排除透明区域和穿透窗口。
        let receiver = mouseReceiver(point)
        InputDiagnostics.event("mouse_receiver", [
            "window_id": String(windowID), "receiver_window_id": receiver.map { String($0) } ?? "unknown",
        ])
        guard receiver == windowID else {
            throw ComputerUseError.stateUnavailable("Mouse-down receiver does not match the snapshot window; observe again")
        }
        accepted = true
        return
    }

    // 后台定向输入不使用前台命中结果；仍检查同 App、同 Space 的上层窗口。
    for above in windows[..<index] {
        guard let owner = above[kCGWindowOwnerPID as String] as? NSNumber else {
            throw ComputerUseError.stateUnavailable("Cannot verify a window above the coordinate target")
        }
        if owner.int32Value == getpid() { continue }
        if owner.int32Value != pid { continue }
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
            InputDiagnostics.event("window_blocked", [
                "window_id": String(windowID), "blocking_window_id": String(aboveID),
                "blocking_pid": owner.stringValue, "blocking_bounds": InputDiagnostics.bounds(aboveBounds),
                "blocking_layer": (above[kCGWindowLayer as String] as? NSNumber)?.stringValue ?? "unknown",
            ])
            throw ComputerUseError.stateUnavailable("Coordinate target is covered by another receiving window; observe again")
        }
    }
    accepted = true
}

private func coordinateWindowBounds(_ info: [String: Any]) -> CGRect? {
    guard let value = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: value as CFDictionary)
}

func validateCoordinateAppPostReceiver(
    frontmostPID: pid_t?, expectedPID: pid_t, focusedWindowMatches: Bool, requiresForeground: Bool = true
) throws {
    // 点击/拖拽保留前台约束；滚轮允许后台，但仍须证明目标 App 的当前焦点窗口匹配。
    guard (!requiresForeground || frontmostPID == expectedPID), focusedWindowMatches else {
        throw ComputerUseError.stateUnavailable("app_post receiver does not match the required snapshot window; observe again")
    }
}
