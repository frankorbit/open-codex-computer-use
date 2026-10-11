import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct SkyKeyboardTarget {
    let windowID: CGWindowID
    let pid: pid_t
}

/// A `cmd`-chord expressed the way AppKit menus advertise their key
/// equivalents: `AXMenuItemCmdChar` plus the `AXMenuItemCmdModifiers` bitmask
/// (1 = shift, 2 = option, 4 = control; 8 marks a non-command equivalent).
struct SkyMenuKeyEquivalent: Equatable {
    let character: String
    let modifiers: Int
}

/// Menu-bar key equivalents (`cmd+a`, `cmd+c`, `cmd+t`, ...) are dispatched by
/// AppKit through `NSMenu`, which only fires for the active app. A background
/// target instead needs the menu item invoked directly, which is exactly what
/// the user's keypress would have triggered. Only single-character keys with
/// a command modifier map to a menu equivalent; everything else (arrows,
/// return, plain characters, non-command chords) is delivered as key events.
func skyMenuKeyEquivalent(for parsed: ParsedKeyPress) -> SkyMenuKeyEquivalent? {
    guard parsed.modifiers.contains(where: { $0.flag == .maskCommand }),
          parsed.displayValue.count == 1
    else {
        return nil
    }

    var modifiers = 0
    for modifier in parsed.modifiers {
        switch modifier.flag {
        case .maskShift:
            modifiers |= 1
        case .maskAlternate:
            modifiers |= 2
        case .maskControl:
            modifiers |= 4
        default:
            break
        }
    }
    return SkyMenuKeyEquivalent(character: parsed.displayValue.uppercased(), modifiers: modifiers)
}

func skyMenuItemMatches(
    cmdChar: String?, cmdModifiers: Int?, enabled: Bool?, equivalent: SkyMenuKeyEquivalent,
) -> Bool {
    guard let cmdChar, let cmdModifiers, enabled == true else {
        return false
    }
    return cmdChar.uppercased() == equivalent.character && cmdModifiers == equivalent.modifiers
}

/// 查找可能跨多次 AX IPC；两种提交路径都必须在查找结束后复验接收者。
func dispatchSkyMenuKey<Item>(
    findMenuItem: () throws -> Item?,
    validateReceiver: () throws -> Void,
    pressMenuItem: (Item) throws -> Void,
    postKey: () throws -> Void,
) throws {
    try validateReceiver()
    let item = try findMenuItem()
    try validateReceiver()
    if let item {
        // 一旦尝试 AXPress，任何错误都向上传递，不能换路重放。
        try pressMenuItem(item)
    } else {
        try postKey()
    }
}

/// 属性未提供与 AX 查询失败必须区分，后者不能伪装成无菜单并继续投递。
func readSkyMenuAttribute(
    _ attribute: String,
    read: () -> (AXError, CFTypeRef?),
) throws -> CFTypeRef? {
    let (result, value) = read()
    switch result {
    case .success: return value
    case .noValue, .attributeUnsupported: return nil
    default:
        throw ComputerUseError.stateUnavailable(
            "Menu query for \(attribute) failed (AXError \(result.rawValue)); "
                + "no key or menu action was sent. Observe before further input.",
        )
    }
}

/// 合成焦点的清理只执行一次；即使投递抛错，也不能吞掉清理失败或重放输入。
func withSkyKeyboardFocus<Context>(
    begin: () throws -> Context,
    prepare: (Context) throws -> Void,
    deliver: () throws -> Void,
    end: (Context) throws -> Void,
) throws {
    let context = try begin()
    let operation = Result {
        try prepare(context)
        try deliver()
    }
    do {
        try end(context)
    } catch {
        InputDiagnostics.event("keyboard_focus_cleanup_failed", ["effect": "unknown"])
        throw ComputerUseError.message(
            "sky_key could not release synthetic focus; input effect and focus state are unknown. "
                + "Observe before further input; do not replay the action.",
        )
    }
    try operation.get()
}

/// 不把前台强制切回：那会覆盖用户自己的切换。只阻止后台目标抢到前台后继续投递。
func validateSkyKeyboardBackground(
    required: Bool, initialPID: pid_t?, currentPID: pid_t?, targetPID: pid_t,
    inputMayHaveOccurred: Bool,
) throws {
    guard required, initialPID != targetPID, currentPID == targetPID else { return }
    let effect = inputMayHaveOccurred
        ? "Input effect is unknown; observe before further input and do not replay."
        : "No keyboard input was sent; observe before further input."
    throw ComputerUseError.message("Background target became the foreground app. " + effect)
}

/// Owner check for keyboard targets. Unlike `sky_click`, the window does not
/// need to be on-screen: keyboard delivery is process-addressed, so a window on
/// another Space or hidden app is a valid target as long as it still exists
/// and belongs to the snapshot's process.
func skyKeyWindowMatchesTarget(
    windowInfo: [[String: Any]],
    windowID: CGWindowID,
    pid: pid_t,
) -> Bool {
    windowInfo.contains { info in
        guard
            let number = info[kCGWindowNumber as String] as? NSNumber,
            number.uint32Value == windowID,
            let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber
        else {
            return false
        }

        return ownerPID.int32Value == pid
    }
}

/// `sky_key`: deliver keyboard input to a background window without changing
/// the real foreground app.
///
/// Keyboard events posted to a pid reach any AppKit window, but Chromium and
/// Electron only insert text while their NSWindow is key (page focus is driven
/// by `OnWindowIsKeyChanged`). The recipe therefore reuses the `sky_click`
/// target-only synthetic-active state, then posts yabai's key-window record
/// pair so the target app makes the window key internally, waits for it to
/// take effect, delivers the ordinary `CGEvent.postToPid` keyboard events (or
/// presses the matching menu item for command chords), and releases the
/// synthetic state again. The real frontmost app keeps its active, key and
/// first-responder state throughout; the target is never raised and the
/// pointer never moves.
enum SkyKeyboardDispatcher {
    private static let dispatchLock = NSLock()
    static let keyWindowFallbackSettleDefaultMilliseconds = 10.0
    static let releaseSettleDefaultMilliseconds = 10.0
    /// The records and key events are ordered, but target applications can
    /// process them asynchronously. macOS 26 live testing dropped occasional
    /// keys with zero delay, so retain a small cross-version safety margin.
    static let keyWindowFallbackSettle = InputTiming.milliseconds(
        "OPEN_COMPUTER_USE_SKY_KEY_SETTLE_MS",
        default: keyWindowFallbackSettleDefaultMilliseconds,
    )
    static let releaseSettle = InputTiming.milliseconds(
        "OPEN_COMPUTER_USE_SKY_KEY_RELEASE_MS",
        default: releaseSettleDefaultMilliseconds,
    )

    static func typeText(
        target: SkyKeyboardTarget,
        text: String,
        spi: SkyLightSPI = .shared,
        validateReceiver: () throws -> Void = {},
    ) throws {
        try deliver(to: target, spi: spi) { validateBackground in
            try validateReceiver()
            try validateBackground()
            InputDiagnostics.event(
                "keyboard_receiver_validated",
                ["target_pid": String(target.pid), "window_id": String(target.windowID)],
            )
            try InputSimulation.typeText(text, pid: target.pid) {
                try validateReceiver()
                try validateBackground()
            }
        }
    }

    static func pressKey(
        target: SkyKeyboardTarget,
        key: String,
        spi: SkyLightSPI = .shared,
        validateReceiver: () throws -> Void = {},
    ) throws {
        // Reject bad key specs before touching the target's focus state.
        let parsed = try KeyPressParser.parse(key)
        try deliver(to: target, spi: spi) { validateBackground in
            try dispatchSkyMenuKey(
                findMenuItem: {
                    guard let equivalent = skyMenuKeyEquivalent(for: parsed) else { return nil as AXUIElement? }
                    return try menuItem(matching: equivalent, pid: target.pid)
                },
                validateReceiver: {
                    try validateReceiver()
                    try validateBackground()
                    InputDiagnostics.event(
                        "keyboard_receiver_validated",
                        ["target_pid": String(target.pid), "window_id": String(target.windowID)],
                    )
                },
                pressMenuItem: { item in
                    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    guard result == .success else {
                        throw ComputerUseError.message(
                            "sky_key menu action for '\(key)' returned AXError \(result.rawValue); effect is unknown. "
                                + "Observe before further input; no key fallback was sent.",
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                },
                postKey: { try InputSimulation.pressKey(key, pid: target.pid) },
            )
        }
    }

    private static func deliver(
        to target: SkyKeyboardTarget,
        spi: SkyLightSPI,
        _ body: (() throws -> Void) throws -> Void,
    ) throws {
        _ = try ExecutionPolicy.current()
        dispatchLock.lock()
        defer {
            dispatchLock.unlock()
        }

        try validate(target: target)

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            InputDiagnostics.event("keyboard_route_selected", ["route": "foreground_pid"])
            try body {}
            return
        }

        guard spi.capability.isAvailable else {
            throw ComputerUseError.message(
                "key_method 'sky_key' is unavailable: \(spi.capability.unavailableReason)",
            )
        }

        try deliverInBackground(to: target, spi: spi, body)
    }

    private static func deliverInBackground(
        to target: SkyKeyboardTarget, spi: SkyLightSPI, _ body: (() throws -> Void) throws -> Void,
    ) throws {
        InputDiagnostics.event("keyboard_route_selected", ["route": "sky_key"])
        let start = TimingLog.now()
        let initialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let backgroundRequired = try ExecutionPolicy.current().isBackground
        func validateBackground(inputMayHaveOccurred: Bool) throws {
            try validateSkyKeyboardBackground(
                required: backgroundRequired, initialPID: initialPID,
                currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                targetPID: target.pid, inputMayHaveOccurred: inputMayHaveOccurred,
            )
        }
        InputDiagnostics.desktopState("keyboard_before_synthetic_focus")
        try withSkyKeyboardFocus(
            begin: {
                try spi.beginSyntheticTargetFocus(targetPID: target.pid, targetWindowID: target.windowID)
            },
            prepare: { focusContext in
                InputDiagnostics.desktopState("keyboard_after_synthetic_focus")
                try validateBackground(inputMayHaveOccurred: false)
                try spi.makeSyntheticTargetWindowKey(focusContext)
                TimingLog.log("sky_key.activate", since: start)
                let keyStart = TimingLog.now()
                waitForKeyWindow(target, spi: spi)
                InputDiagnostics.desktopState("keyboard_after_key_window")
                try validateBackground(inputMayHaveOccurred: false)
                TimingLog.log("sky_key.key_window", since: keyStart)
            },
            deliver: {
                let deliverStart = TimingLog.now()
                try body { try validateBackground(inputMayHaveOccurred: false) }
                InputDiagnostics.desktopState("keyboard_after_input")
                TimingLog.log("sky_key.deliver", since: deliverStart)
                if releaseSettle > 0 {
                    Thread.sleep(forTimeInterval: releaseSettle)
                }
                try validateBackground(inputMayHaveOccurred: true)
            },
            end: { focusContext in
                try spi.endSyntheticTargetFocus(focusContext)
                InputDiagnostics.desktopState("keyboard_after_focus_release")
            },
        )
        try validateBackground(inputMayHaveOccurred: true)
        TimingLog.log("sky_key.total", since: start)
    }

    private static func waitForKeyWindow(_: SkyKeyboardTarget, spi _: SkyLightSPI) {
        if keyWindowFallbackSettle > 0 {
            Thread.sleep(forTimeInterval: keyWindowFallbackSettle)
        }
    }

    private static func validate(target: SkyKeyboardTarget) throws {
        // A hidden app (cmd+h) never makes its windows key, so keys would be
        // silently dropped. Fail closed instead of unhiding on the user's behalf.
        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw ComputerUseError.stateUnavailable(
                "sky_key target app is hidden. Unhide it first; sky_key does not change window visibility.",
            )
        }

        // `.optionAll`, not `.optionIncludingWindow`: the latter omits windows
        // that are off-screen (hidden app, minimized, or on another Space).
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID,
        ) as? [[String: Any]] ?? []
        guard skyKeyWindowMatchesTarget(
            windowInfo: windowInfo,
            windowID: target.windowID,
            pid: target.pid,
        ) else {
            throw ComputerUseError.stateUnavailable(
                "sky_key target window no longer exists or is no longer owned by the target app. "
                    + "Run get_app_state again.",
            )
        }
    }

    // MARK: - Menu-bar key equivalents

    private static func menuItem(matching equivalent: SkyMenuKeyEquivalent, pid: pid_t) throws -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = try copyValue(application, kAXMenuBarAttribute) else {
            return nil
        }
        guard CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
            throw ComputerUseError.stateUnavailable("Invalid menu bar AX type; no key or menu action was sent.")
        }
        // 已验证 CF 类型，才转换为 AX 元素。
        // swiftlint:disable:next force_cast
        return try firstMenuItem(in: menuBar as! AXUIElement, matching: equivalent, depth: 0)
    }

    private static func firstMenuItem(
        in element: AXUIElement, matching equivalent: SkyMenuKeyEquivalent, depth: Int,
    ) throws -> AXUIElement? {
        guard depth < 6 else {
            return nil
        }

        for child in try copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let role = try copyValue(child, kAXRoleAttribute) as? String
            if role == kAXMenuItemRole as String,
               try skyMenuItemMatches(
                   cmdChar: copyValue(child, "AXMenuItemCmdChar") as? String,
                   cmdModifiers: (copyValue(child, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
                   enabled: (copyValue(child, kAXEnabledAttribute) as? NSNumber)?.boolValue,
                   equivalent: equivalent,
               )
            {
                return child
            }

            if let nested = try firstMenuItem(in: child, matching: equivalent, depth: depth + 1) {
                return nested
            }
        }

        return nil
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        try readSkyMenuAttribute(attribute) {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (result, value)
        }
    }
}
