import AppKit
import ApplicationServices
import Foundation

struct HoverPopupClickRequest {
    let token: String
    let point: CGPoint

    init(arguments: [String: Any]) throws {
        guard let token = arguments["popup_token"] as? String, UUID(uuidString: token) != nil,
              arguments["element_index"] == nil,
              arguments["click_method"] == nil || arguments["click_method"] as? String == "global",
              arguments["mouse_button"] == nil || arguments["mouse_button"] as? String == "left",
              let pixelX = arguments["x"] as? NSNumber, CFGetTypeID(pixelX) != CFBooleanGetTypeID(),
              let pixelY = arguments["y"] as? NSNumber, CFGetTypeID(pixelY) != CFBooleanGetTypeID(),
              pixelX.doubleValue.isFinite, pixelY.doubleValue.isFinite,
              pixelX.doubleValue >= 0, pixelY.doubleValue >= 0
        else {
            throw ComputerUseError.invalidArguments("popup_token requires a UUID, popup screenshot x/y, "
                + "and global left single click")
        }
        if let count = arguments["click_count"] {
            guard let number = count as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 1
            else {
                throw ComputerUseError.invalidArguments("Popup click supports only one click")
            }
        }
        self.token = token
        point = CGPoint(x: pixelX.doubleValue, y: pixelY.doubleValue)
    }
}

struct HoverPopupLease {
    let popup: HoverPopupObservation
    let rootWindowID: CGWindowID?
    let rootBounds: CGRect?
    let createdAt: TimeInterval

    func globalPoint(for point: CGPoint, snapshot: AppSnapshot, now: TimeInterval) throws -> CGPoint {
        guard now >= createdAt, now - createdAt <= 30,
              snapshot.app.pid == popup.pid, snapshot.targetWindowID == rootWindowID,
              snapshot.windowBounds == rootBounds,
              popup.pixelSize.width > 0, popup.pixelSize.height > 0,
              point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < popup.pixelSize.width, point.y < popup.pixelSize.height
        else {
            throw ComputerUseError.stateUnavailable("Popup observation expired or target changed; observe again")
        }
        return CGPoint(
            x: popup.bounds.minX + point.x * popup.bounds.width / popup.pixelSize.width,
            y: popup.bounds.minY + point.y * popup.bounds.height / popup.pixelSize.height
        )
    }
}

struct HoverPopupCache {
    private var leases: [String: HoverPopupLease] = [:]

    mutating func record(_ popups: [HoverPopupObservation], snapshot: AppSnapshot, now: TimeInterval) {
        leases = Dictionary(uniqueKeysWithValues: popups.map {
            ($0.token.lowercased(), HoverPopupLease(
                popup: $0,
                rootWindowID: snapshot.targetWindowID,
                rootBounds: snapshot.windowBounds,
                createdAt: now
            ))
        })
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
    validate: () throws -> Void,
    submit: () throws -> Void,
    readBack: () throws -> Result
) throws -> Result {
    try validate()
    do {
        try submit()
        return try readBack()
    } catch {
        throw ComputerUseError.message("Popup click input may have occurred; observe before further input. "
            + "No retry was sent. \(error.localizedDescription)")
    }
}

func validateHoverPopupReceiver(_ popup: HoverPopupObservation, point: CGPoint, snapshot: AppSnapshot) throws {
    // 弹层已打开时不激活/抬升主窗口，否则会把弹层关掉。
    guard let window = snapshot.windowElement, InputSimulation.isForegroundWindow(snapshot.app, window: window),
          let rootID = snapshot.targetWindowID, let rootBounds = snapshot.windowBounds,
          let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    else {
        throw ComputerUseError.stateUnavailable("Popup foreground context changed; observe again")
    }
    try InputSimulation.requireReleasedMouseButtons()
    try validateCoordinateWindow(
        windowID: rootID,
        pid: snapshot.app.pid,
        bounds: rootBounds,
        point: CGPoint(x: rootBounds.midX, y: rootBounds.midY),
        windows: windows,
        requireUnoccludedPoint: false,
        identityOnly: true,
        spacesForWindow: { _ in nil }
    )
    try validateCoordinateWindow(
        windowID: popup.windowID,
        pid: popup.pid,
        bounds: popup.bounds,
        point: point,
        windows: windows,
        requireUnoccludedPoint: true,
        spacesForWindow: { _ in nil },
        mouseReceiver: foregroundMouseReceiver
    )
}
