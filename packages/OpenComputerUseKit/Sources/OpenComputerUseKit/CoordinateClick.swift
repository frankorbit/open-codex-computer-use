import ApplicationServices
import Foundation

struct CoordinateClickHit {
    let target: CoordinateClickTarget
    let performAX: (String) throws -> AXError
}

struct CoordinateClickBackend {
    let hitTest: (CGPoint, AppSnapshot) throws -> CoordinateClickHit?
    let performMouse: (CGPoint, MouseButtonKind, Int, AppSnapshot) throws -> Void
}

struct CoordinateClickTarget {
    let role: String?
    let frame: CGRect?
    let actions: [String]
    let belongsToWindow: Bool
}

func globalPointFromWindowPoint(_ point: CGPoint, windowBounds: CGRect) -> CGPoint {
    CGPoint(x: windowBounds.minX + point.x, y: windowBounds.minY + point.y)
}

func dispatchCoordinateClick(
    at point: CGPoint,
    target: CoordinateClickTarget?,
    button: MouseButtonKind,
    clickCount: Int,
    performAX: (String) throws -> AXError,
    performMouse: () throws -> Void
) throws {
    // 命中其他窗口时不能把旧截图坐标投递到弹窗或被遮挡的窗口。
    guard let target, target.belongsToWindow else {
        throw ComputerUseError.stateUnavailable("Coordinate hit belongs to a different or unverified window; run get_app_state again")
    }

    // 多击、中键和容器区域保留鼠标语义；不搜索后代或选择祖先列表项。
    let controlRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXMenuItemRole, "AXLink",
    ]
    guard clickCount == 1, button == .left || button == .right,
          let role = target.role, controlRoles.contains(role),
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
