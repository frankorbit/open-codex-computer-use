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
    mouseReceiver: (CGPoint) -> CGWindowID? = { _ in nil },
    backgroundWindows: (Bool) throws -> CoordinateWindowObstructions = { _ in
        throw ComputerUseError.stateUnavailable("Background window order evidence is unavailable; observe again")
    },
    receivingWindow: CoordinateReceivingWindow? = nil
) throws {
    var accepted = false
    defer { InputDiagnostics.event(
        "window_validation",
        [
            "accepted": String(accepted),
            "window_id": String(windowID),
            "target_pid": String(pid),
            "require_unoccluded": String(requireUnoccludedPoint)
        ]
    ) }
    // 承载目标元素的同进程弹层可以伸出主窗口；点击位置落在其中即可。
    let pointInTarget = bounds.contains(point) || receivingWindow?.bounds.contains(point) == true
    guard point.x.isFinite, point.y.isFinite, bounds.width > 0, bounds.height > 0, pointInTarget,
          let index = windows
          .firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
    else {
        throw ComputerUseError
            .stateUnavailable("Coordinate target is missing or outside its snapshot window; observe again")
    }
    let current = windows[index]
    guard (current[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          let currentBounds = coordinateWindowBounds(current), currentBounds == bounds,
          (current[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
    else {
        throw ComputerUseError
            .stateUnavailable("Coordinate target window changed owner, geometry or visibility; observe again")
    }

    if let receivingWindow {
        // 接收窗口必须仍是同一进程、同一位置的屏上窗口；变化后旧的命中结论不能复用。
        guard let info = windows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == receivingWindow.windowID
        }), (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              coordinateWindowBounds(info) == receivingWindow.bounds,
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true else {
            throw ComputerUseError
                .stateUnavailable("Popup hosting the target changed or closed; observe again")
        }
    }

    if requireUnoccludedPoint, (current[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != true {
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
            "window_id": String(windowID), "receiver_window_id": receiver.map { String($0) } ?? "unknown"
        ])
        guard receiver == windowID || (receivingWindow != nil && receiver == receivingWindow?.windowID) else {
            throw ComputerUseError
                .stateUnavailable("Mouse-down receiver does not match the snapshot window; observe again")
        }
        accepted = true
        return
    }

    // 后台定向输入不使用前台命中结果；仍检查同 App、同 Space 的上层窗口。
    let evidence = try backgroundWindows((current[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true)
    try validateCoordinateObstructions(
        evidence, windowID: windowID, pid: pid, point: point, spacesForWindow: spacesForWindow,
        isSharingIndicator: { WindowSharingIndicator.isIndicator($0, windows: windows) },
        receivingWindowID: receivingWindow?.windowID
    )
    accepted = true
}

func validateCoordinateObstructions(
    _ evidence: CoordinateWindowObstructions, windowID: CGWindowID, pid: pid_t, point: CGPoint,
    spacesForWindow: (CGWindowID) -> [UInt64]?,
    isSharingIndicator: ([String: Any]) -> Bool = { _ in false },
    receivingWindowID: CGWindowID? = nil
) throws {
    for above in evidence.windows {
        guard let owner = above[kCGWindowOwnerPID as String] as? NSNumber else {
            throw ComputerUseError.stateUnavailable("Cannot verify a window above the coordinate target")
        }
        if owner.int32Value == getpid() { continue }
        if owner.int32Value != pid { continue }
        // 承载目标元素的弹层接收这次点击，不算遮挡；它之上的其他窗口仍按遮挡处理。
        if let receivingWindowID,
           (above[kCGWindowNumber as String] as? NSNumber)?.uint32Value == receivingWindowID { continue }
        // 系统为被采集窗口加的共享指示器不接收应用输入，不算遮挡。
        if isSharingIndicator(above) { continue }
        guard (above[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              (above[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }
        guard let aboveBounds = coordinateWindowBounds(above) else {
            throw ComputerUseError.stateUnavailable("Cannot verify bounds of a window above the coordinate target")
        }
        guard aboveBounds.contains(point) else { continue }
        // 不同 Space 可以有完全相同的坐标，不能据此认定互相遮挡。
        guard let aboveID = (above[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let targetSpaces = spacesForWindow(windowID), !targetSpaces.isEmpty,
              let aboveSpaces = spacesForWindow(aboveID), !aboveSpaces.isEmpty
        else {
            throw ComputerUseError.stateUnavailable("Cannot verify Spaces of overlapping windows; observe again")
        }
        if !Set(targetSpaces).isDisjoint(with: aboveSpaces) {
            guard evidence.hasRelativeOrder else {
                throw ComputerUseError
                    .stateUnavailable(
                        "Cannot verify relative order of overlapping off-screen target windows; observe again"
                    )
            }
            InputDiagnostics.event("window_blocked", [
                "window_id": String(windowID), "blocking_window_id": String(aboveID),
                "blocking_pid": owner.stringValue, "blocking_bounds": InputDiagnostics.bounds(aboveBounds),
                "blocking_layer": (above[kCGWindowLayer as String] as? NSNumber)?.stringValue ?? "unknown"
            ])
            throw ComputerUseError
                .stateUnavailable("Coordinate target is covered by another receiving window; observe again")
        }
    }
}

private func coordinateWindowBounds(_ info: [String: Any]) -> CGRect? {
    guard let value = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: value as CFDictionary)
}

func validateCoordinateAppPostReceiver(focusedWindowMatches: Bool?) throws {
    // 进程和窗口已独立校验。AX 不可用可定向投递，已知错误窗口则必须拒绝。
    guard focusedWindowMatches != false else {
        throw ComputerUseError.stateUnavailable("app_post receiver does not match the snapshot window; observe again")
    }
}

/// 可选 AX IPC 前后都检查窗口；已知错误接收者不能因降级而绕过。
func validateCoordinateAppPostTarget(
    validateWindow: () throws -> Void,
    readFocusedWindowMatch: () throws -> Bool?
) throws {
    try validateWindow()
    try validateCoordinateAppPostReceiver(focusedWindowMatches: readFocusedWindowMatch())
    try validateWindow()
}
