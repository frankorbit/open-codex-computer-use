import ApplicationServices
import Foundation

struct CoordinateClickHit {
    let target: CoordinateClickTarget
    let performAX: (String) throws -> AXError
}

struct CoordinateClickBackend {
    let validateWindow: (CGPoint, AppSnapshot) throws -> Void
    let hitTest: (CGPoint, AppSnapshot) throws -> CoordinateClickHit?
    let performMouse: (CGPoint, MouseButtonKind, Int, AppSnapshot) throws -> Void
}

struct CoordinateClickTarget {
    let role: String?
    let frame: CGRect?
    let actions: [String]
    let belongsToWindow: Bool?
}

func globalPointFromWindowPoint(_ point: CGPoint, windowBounds: CGRect) -> CGPoint {
    CGPoint(x: windowBounds.minX + point.x, y: windowBounds.minY + point.y)
}

func dispatchCoordinateClick(
    at point: CGPoint,
    target: CoordinateClickTarget?,
    button: MouseButtonKind,
    clickCount: Int,
    validateWindow: () throws -> Void,
    performAX: (String) throws -> AXError,
    performMouse: () throws -> Void
) throws {
    // AX 无命中不代表窗口失效；窗口证据必须独立校验。
    try validateWindow()
    if target?.belongsToWindow == false {
        throw ComputerUseError.stateUnavailable("Coordinate hit belongs to a different or unverified window; run get_app_state again")
    }

    // 多击、中键和容器区域保留鼠标语义；不搜索后代或选择祖先列表项。
    let controlRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXMenuItemRole, "AXLink",
    ]
    guard clickCount == 1, button == .left || button == .right,
          let target, target.belongsToWindow == true, let role = target.role, controlRoles.contains(role),
          let frame = target.frame, frame.contains(point) else {
        try performMouse()
        return
    }
    let desiredAction = button == .right ? kAXShowMenuAction : kAXPressAction
    guard let action = target.actions.first(where: { $0 == desiredAction }) else {
        try performMouse()
        return
    }

    // 动作已发出后，错误或超时不代表未生效，不能再回退重放鼠标事件。
    let result = try performAX(action)
    guard result == .success else {
        throw ComputerUseError.message("Coordinate AX action returned \(result.rawValue); effect is unknown. Observe before further input; no mouse fallback was sent.")
    }
}

func coordinateHitTestHasElement(_ result: AXError) throws -> Bool {
    switch result {
    case .success: return true
    case .noValue, .notImplemented: return false
    default:
        throw ComputerUseError.stateUnavailable("AX hit test failed (\(result.rawValue)); observe again before input")
    }
}

func coordinateMouseMethod(button: MouseButtonKind, clickCount: Int, globalEnabled: Bool) -> ClickMethod {
    if globalEnabled { return .global }
    return button == .left && (1...2).contains(clickCount) ? .skyClick : .appPost
}
