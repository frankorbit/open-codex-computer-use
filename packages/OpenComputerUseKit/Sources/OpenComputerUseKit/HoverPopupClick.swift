import AppKit
import ApplicationServices
import Foundation

struct HoverPopupClickRequest {
    let token: String
    let point: CGPoint
    let method: ClickMethod

    init(arguments: [String: Any]) throws {
        guard let token = arguments["popup_token"] as? String, UUID(uuidString: token) != nil,
              arguments["element_index"] == nil,
              arguments["click_method"] == nil || arguments["click_method"] is String,
              arguments["mouse_button"] == nil || arguments["mouse_button"] as? String == "left",
              let pixelX = arguments["x"] as? NSNumber, CFGetTypeID(pixelX) != CFBooleanGetTypeID(),
              let pixelY = arguments["y"] as? NSNumber, CFGetTypeID(pixelY) != CFBooleanGetTypeID(),
              pixelX.doubleValue.isFinite, pixelY.doubleValue.isFinite,
              pixelX.doubleValue >= 0, pixelY.doubleValue >= 0
        else {
            throw ComputerUseError.invalidArguments("popup_token requires a UUID, popup screenshot x/y, "
                + "and explicit sky_click or compatible global left single click")
        }
        let method = try parseClickMethod(arguments["click_method"] as? String ?? "global")
        guard method == .global || method == .skyClick else {
            throw ComputerUseError
                .invalidArguments("Popup click requires sky_click or global; automatic fallback is disabled")
        }
        if let count = arguments["click_count"] {
            guard let number = count as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 1
            else {
                throw ComputerUseError.invalidArguments("Popup click supports only one click")
            }
        }
        self.token = token
        self.method = method
        point = CGPoint(x: pixelX.doubleValue, y: pixelY.doubleValue)
    }
}

struct HoverPopupLease {
    let popup: HoverPopupObservation
    let rootWindowID: CGWindowID?
    let rootBounds: CGRect?
    let createdAt: TimeInterval
    let method: ClickMethod

    init(
        popup: HoverPopupObservation, rootWindowID: CGWindowID?, rootBounds: CGRect?,
        createdAt: TimeInterval, method: ClickMethod = .global
    ) {
        self.popup = popup
        self.rootWindowID = rootWindowID
        self.rootBounds = rootBounds
        self.createdAt = createdAt
        self.method = method
    }

    func globalPoint(
        for point: CGPoint, snapshot: AppSnapshot, now: TimeInterval, method: ClickMethod = .global
    ) throws -> CGPoint {
        let policy = try ExecutionPolicy.current()
        guard method == self.method, popup.clickMethod(policy: policy) == method,
              createdAt.isFinite, now.isFinite, now >= createdAt, now - createdAt <= 30,
              let rootWindowID, rootWindowID != 0, rootWindowID != popup.windowID,
              let rootBounds, HoverPopupObservation.validBounds(rootBounds),
              popup.windowID != 0, popup.pid > 0, HoverPopupObservation.validBounds(popup.bounds),
              snapshot.app.pid == popup.pid, snapshot.targetWindowID == rootWindowID,
              snapshot.windowBounds == rootBounds,
              popup.pixelSize.width.isFinite, popup.pixelSize.height.isFinite,
              popup.pixelSize.width > 0, popup.pixelSize.height > 0,
              point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < popup.pixelSize.width, point.y < popup.pixelSize.height
        else {
            throw ComputerUseError.stateUnavailable("Popup observation expired or target changed; observe again")
        }
        let result = CGPoint(
            x: popup.bounds.minX + (point.x / popup.pixelSize.width) * popup.bounds.width,
            y: popup.bounds.minY + (point.y / popup.pixelSize.height) * popup.bounds.height
        )
        guard result.x.isFinite, result.y.isFinite, popup.bounds.contains(result) else {
            throw ComputerUseError.stateUnavailable("Popup coordinate is outside the observed window")
        }
        return result
    }
}

struct HoverPopupCache {
    private var leases: [String: HoverPopupLease] = [:]

    mutating func record(_ popups: [HoverPopupObservation], snapshot: AppSnapshot, now: TimeInterval) {
        clear()
        guard let policy = try? ExecutionPolicy.current(), now.isFinite else { return }
        // 拒绝重复 token，不能因字典覆盖而把凭证重绑定到另一个窗口。
        let counts = Dictionary(grouping: popups, by: { $0.token.lowercased() }).mapValues(\.count)
        for popup in popups {
            guard UUID(uuidString: popup.token) != nil, counts[popup.token.lowercased()] == 1,
                  let method = popup.clickMethod(policy: policy) else { continue }
            let lease = HoverPopupLease(
                popup: popup,
                rootWindowID: snapshot.targetWindowID,
                rootBounds: snapshot.windowBounds,
                createdAt: now,
                method: method
            )
            guard (try? lease.globalPoint(for: .zero, snapshot: snapshot, now: now, method: method)) != nil
            else { continue }
            leases[popup.token.lowercased()] = lease
        }
    }

    mutating func clear() {
        leases.removeAll()
    }

    mutating func take(_ token: String) throws -> HoverPopupLease {
        // 任意点击尝试都消耗整份弹层观察，失败后不能重放或借用另一个 token。
        defer { clear() }
        guard let lease = leases[token.lowercased()] else {
            throw ComputerUseError.stateUnavailable("No current popup_token; use fresh hover evidence")
        }
        return lease
    }
}

func dispatchPopupClick<Result>(
    method: ClickMethod = .global,
    validate: () throws -> Void,
    submit: () throws -> Void,
    readBack: () throws -> Result
) throws -> Result {
    let policy = try ExecutionPolicy.current()
    if method == .global {
        try policy.requireForeground("Popup global click")
    } else if method != .skyClick {
        throw ComputerUseError.invalidArguments("Popup input has no automatic or alternate route")
    }
    try validate()
    do {
        try submit()
        return try readBack()
    } catch {
        throw ComputerUseError.message("Popup click input may have occurred; observe before further input. "
            + "No retry was sent. \(error.localizedDescription)")
    }
}

func validateHoverPopupReceiver(
    _ popup: HoverPopupObservation, point: CGPoint, snapshot: AppSnapshot, method: ClickMethod = .global
) throws {
    let policy = try ExecutionPolicy.current()
    // 弹层已打开时不激活/抬升主窗口，否则会把弹层关掉。
    guard popup.clickMethod(policy: policy) == method,
          let window = snapshot.windowElement,
          HoverPopupObservation.rootMatchesSnapshot(snapshot, root: window),
          method != .global || InputSimulation.isForegroundWindow(snapshot.app, window: window),
          method != .skyClick || SkyLightSPI.shared.capability.isAvailable
    else {
        throw ComputerUseError.stateUnavailable("Popup input capability or root context changed; observe again")
    }
    try InputSimulation.requireReleasedMouseButtons()
    try validateHoverPopupWindows(
        popup, point: point, snapshot: snapshot, mouseReceiver: foregroundMouseReceiver
    )
}

/// receiver 可能等待主队列；返回后必须重读元数据，不能沿用排队前的窗口几何。
func validateHoverPopupWindows(
    _ popup: HoverPopupObservation, point: CGPoint, snapshot: AppSnapshot,
    query: () -> [[String: Any]]? = {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    },
    mouseReceiver: (CGPoint) -> CGWindowID?
) throws {
    try validateHoverPopupWindowMetadata(popup, point: point, snapshot: snapshot, windows: query())
    guard mouseReceiver(point) == popup.windowID else {
        throw ComputerUseError.stateUnavailable("Popup exact mouse receiver changed or is unknown; observe again")
    }
    try validateHoverPopupWindowMetadata(popup, point: point, snapshot: snapshot, windows: query())
}

/// 两次查询共用完整校验；同 PID 或相同 windowID 不能替代身份、几何及可见顺序。
private func validateHoverPopupWindowMetadata(
    _ popup: HoverPopupObservation, point: CGPoint, snapshot: AppSnapshot, windows: [[String: Any]]?
) throws {
    guard let windows, let rootID = snapshot.targetWindowID, let rootBounds = snapshot.windowBounds,
          rootID != popup.windowID, snapshot.app.pid == popup.pid,
          point.x.isFinite, point.y.isFinite, popup.bounds.contains(point),
          HoverPopupObservation.geometricallyRelated(popup.bounds, rootBounds)
    else { throw ComputerUseError.stateUnavailable("Popup target does not match its bound root; observe again") }
    for (id, bounds) in [(rootID, rootBounds), (popup.windowID, popup.bounds)] {
        let matches = windows.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
        guard matches.count == 1, let info = matches.first,
              let current = HoverPopupObservation.windowInfo(info), current.isVisible,
              current.pid == popup.pid, current.bounds == bounds
        else {
            throw ComputerUseError
                .stateUnavailable("Popup or root identity/geometry/visibility changed; observe again")
        }
    }
    guard let rootIndex = windows
        .firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == rootID }),
        let popupIndex = windows
        .firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == popup.windowID }),
        popupIndex < rootIndex
    else {
        throw ComputerUseError
            .stateUnavailable("Popup is covered or its exact mouse receiver is unknown; observe again")
    }
}

/// service 在消耗 token 后调用；慢速 AX 校验后再次检查 TTL，再执行唯一指定的输入路由。
func validateHoverPopupClick(
    _ lease: HoverPopupLease, request: HoverPopupClickRequest, snapshot: AppSnapshot,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    validateReceiver: (HoverPopupObservation, CGPoint, AppSnapshot, ClickMethod) throws -> Void = {
        try validateHoverPopupReceiver($0, point: $1, snapshot: $2, method: $3)
    }
) throws -> CGPoint {
    guard request.token.lowercased() == lease.popup.token.lowercased() else {
        throw ComputerUseError.stateUnavailable("Popup request does not match the consumed token")
    }
    let point = try lease.globalPoint(for: request.point, snapshot: snapshot, now: now(), method: request.method)
    try validateReceiver(lease.popup, point, snapshot, request.method)
    return try lease.globalPoint(for: request.point, snapshot: snapshot, now: now(), method: request.method)
}

/// 保留 lease 上下文，使锁等待、焦点准备和 primer 后仍能复验原凭证与点击点。
func submitHoverPopupClick(
    _ lease: HoverPopupLease, request: HoverPopupClickRequest, snapshot: AppSnapshot, point: CGPoint
) throws {
    try submitHoverPopupClick(lease.popup, point: point, method: request.method) {
        guard try validateHoverPopupClick(lease, request: request, snapshot: snapshot) == point else {
            throw ComputerUseError.stateUnavailable("Popup submission point changed; observe again")
        }
    }
}

/// 旧 global 调用保持兼容；后台提交必须携带完整复验，不能静默省略安全门。
func submitHoverPopupClick(
    _ popup: HoverPopupObservation, point: CGPoint, method: ClickMethod,
    validateBeforeSubmission: (() throws -> Void)? = nil
) throws {
    if method == .skyClick, validateBeforeSubmission == nil {
        throw ComputerUseError.stateUnavailable("Popup sky_click requires submission validation; no input was sent")
    }
    let eventPoint = inputEventPoint(fromScreenStatePoint: point)
    switch method {
    case .skyClick:
        try InputDiagnostics.input(route: method, point: eventPoint) {
            try InputSimulation.clickWithSkyLight(
                at: eventPoint,
                windowPoint: CGPoint(x: point.x - popup.bounds.minX, y: point.y - popup.bounds.minY),
                windowBounds: popup.bounds, windowID: popup.windowID, clickCount: 1, pid: popup.pid, button: .left,
                validateBeforeSubmission: validateBeforeSubmission
            )
        }
    case .global:
        try InputDiagnostics.input(route: method, point: eventPoint) {
            try InputSimulation.clickGlobally(at: eventPoint, button: .left, clickCount: 1)
        }
    default:
        throw ComputerUseError.invalidArguments("Popup input has no automatic or alternate route")
    }
}
