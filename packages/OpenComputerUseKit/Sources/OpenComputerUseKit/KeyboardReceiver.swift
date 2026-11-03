import AppKit
import ApplicationServices
import Foundation

/// 同步读取目标 App 的焦点，不使用观察快照中的 focusedElement，也不要求它占据系统前台。
enum KeyboardReceiver {
    static func validateWindow(in snapshot: AppSnapshot) throws {
        guard !snapshot.app.runningApplication.isTerminated, !snapshot.app.runningApplication.isHidden,
              let windowID = snapshot.targetWindowID,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              skyKeyWindowMatchesTarget(windowInfo: windows, windowID: windowID, pid: snapshot.app.pid)
        else {
            throw ComputerUseError.stateUnavailable("Keyboard target window is stale or hidden; no input was sent.")
        }
        // 目标已在前台时，已知另一个窗口获得焦点仍拒绝；AX 缺失本身不是错误。
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.app.pid {
            try validateCoordinateAppPostReceiver(focusedWindowMatches: optionalFocusedWindowMatches(in: snapshot))
        }
    }

    static func optionalFocusedWindowMatches(in snapshot: AppSnapshot) throws -> Bool? {
        guard let expected = snapshot.windowElement else { return nil }
        let app = AXUIElementCreateApplication(snapshot.app.pid)
        let current = try readOptionalInputAXAttribute(kAXFocusedWindowAttribute) {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            return (result, value)
        }
        guard let current else { return nil }
        guard CFGetTypeID(current) == AXUIElementGetTypeID() else {
            throw unavailable("Invalid focused window AX type")
        }
        return CFEqual(expected, current)
    }

    static func read(in snapshot: AppSnapshot, requireEditable: Bool) throws -> AXUIElement {
        guard !snapshot.app.runningApplication.isTerminated, !snapshot.app.runningApplication.isHidden,
              let window = snapshot.windowElement, let windowID = snapshot.targetWindowID,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              skyKeyWindowMatchesTarget(windowInfo: windows, windowID: windowID, pid: snapshot.app.pid)
        else {
            throw unavailable("Keyboard target window is stale or hidden")
        }
        let reader = KeyboardReceiverAXReader()
        let app = AXUIElementCreateApplication(snapshot.app.pid)
        let focusedWindow = try reader.element(app, attribute: kAXFocusedWindowAttribute)
        try requireSameKeyboardReceiver(window, current: focusedWindow)
        guard requireEditable else { return focusedWindow }

        let focused = try reader.element(app, attribute: kAXFocusedUIElementAttribute)
        var owner: pid_t = 0
        guard AXUIElementGetPid(focused, &owner) == .success, owner == snapshot.app.pid else {
            throw unavailable("Focused input belongs to another process")
        }
        let inputWindow = try reader.element(focused, attribute: kAXWindowAttribute)
        try requireSameKeyboardReceiver(window, current: inputWindow)
        let role = try reader.value(focused, attribute: kAXRoleAttribute) as? String
        let description = try reader.value(focused, attribute: kAXRoleDescriptionAttribute) as? String
        let enabled = try (reader.value(focused, attribute: kAXEnabledAttribute) as? NSNumber)?.boolValue
        let editable = try (reader.value(focused, attribute: "AXEditable") as? NSNumber)?.boolValue
        let readOnly = try (reader.value(focused, attribute: "AXReadOnly") as? NSNumber)?.boolValue
        var settable = DarwinBoolean(false)
        let result = try reader.query(focused, attribute: kAXValueAttribute, operation: "settable") {
            AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        }
        guard result == .success || result == .attributeUnsupported || result == .noValue else {
            throw unavailable("Live editable capability query failed (\(result.rawValue))")
        }
        try validateEditableKeyboardReceiver(
            role: role, description: description, enabled: enabled,
            editable: editable, readOnly: readOnly, valueSettable: result == .success && settable.boolValue
        )
        return focused
    }

    private static func unavailable(_ reason: String) -> ComputerUseError {
        .stateUnavailable("\(reason). Observe the target and focus its input before typing; no text was sent.")
    }
}

func requireSameKeyboardReceiver(_ expected: AXUIElement, current: AXUIElement) throws {
    guard CFEqual(expected, current) else {
        throw ComputerUseError.stateUnavailable(
            "Keyboard receiver changed. Observe before further input; no keys were sent."
        )
    }
}

func validateEditableKeyboardReceiver(
    role: String?, description: String?, enabled: Bool?,
    editable: Bool? = nil, readOnly: Bool? = nil, valueSettable: Bool = false
) throws {
    // AXValue 可写的滑块或复选框不等于文本输入框。
    let textRole = canUseKeyboardTextFallback(role: role, roleDescription: description, isValueSettable: false)
    let editableCombo = role == kAXComboBoxRole && (editable == true || valueSettable)
    guard enabled != false, editable != false, readOnly != true, textRole || editableCombo
    else {
        throw ComputerUseError.stateUnavailable(
            "Text input requires a live focused editable text element. "
                + "Click a text entry area first; no text was sent."
        )
    }
}

func focusedElementSummary(rendered: String?, role: String?, hasFocusedElement: Bool) -> String? {
    if let rendered { return rendered }
    guard hasFocusedElement else { return nil }
    // 不伪造元素索引，也不把树裁剪解释成未聚焦。
    return "\(role ?? "UI element") (outside the rendered tree; no element index available)"
}

struct KeyboardInputBackend {
    typealias Paste = (SkyKeyboardTarget, String, SkyPasteRoute, () throws -> Void) throws -> Void

    var readReceiver: (AppSnapshot, Bool) throws -> AXUIElement
    var typeText: (SkyKeyboardTarget, String, () throws -> Void) throws -> Void
    var pressKey: (SkyKeyboardTarget, String, () throws -> Void) throws -> Void

    var validateWindow: (AppSnapshot) throws -> Void = { try KeyboardReceiver.validateWindow(in: $0) }
    var validateMenuEscape: (AppSnapshot) throws -> Void = { try KeyboardEscapeGuard.validate(in: $0) }
    var pasteText: Paste = { target, text, route, validate in
        try SkyKeyboardDispatcher.pasteText(target: target, text: text, route: route, validateReceiver: validate)
    }

    static var live: KeyboardInputBackend {
        KeyboardInputBackend(
            readReceiver: { try KeyboardReceiver.read(in: $0, requireEditable: $1) },
            typeText: { target, text, validate in
                try SkyKeyboardDispatcher.typeText(target: target, text: text, validateReceiver: validate)
            },
            pressKey: { target, key, validate in
                try SkyKeyboardDispatcher.pressKey(target: target, key: key, validateReceiver: validate)
            }
        )
    }
}
