import AppKit
import ApplicationServices
import Foundation

/// 同步读取目标 App 的焦点，不使用观察快照中的 focusedElement，也不要求它占据系统前台。
enum KeyboardReceiver {
    static func read(in snapshot: AppSnapshot, requireEditable: Bool) throws -> AXUIElement {
        guard !snapshot.app.runningApplication.isTerminated, !snapshot.app.runningApplication.isHidden,
              let window = snapshot.windowElement, let windowID = snapshot.targetWindowID,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              skyKeyWindowMatchesTarget(windowInfo: windows, windowID: windowID, pid: snapshot.app.pid)
        else {
            throw unavailable("Keyboard target window is stale or hidden")
        }
        let app = AXUIElementCreateApplication(snapshot.app.pid)
        let focusedWindow = try element(app, attribute: kAXFocusedWindowAttribute)
        try requireSameKeyboardReceiver(window, current: focusedWindow)
        guard requireEditable else { return focusedWindow }

        let focused = try element(app, attribute: kAXFocusedUIElementAttribute)
        var owner: pid_t = 0
        guard AXUIElementGetPid(focused, &owner) == .success, owner == snapshot.app.pid else {
            throw unavailable("Focused input belongs to another process")
        }
        let inputWindow = try element(focused, attribute: kAXWindowAttribute)
        try requireSameKeyboardReceiver(window, current: inputWindow)
        let role = try optionalAttribute(focused, name: kAXRoleAttribute) as? String
        let description = try optionalAttribute(focused, name: kAXRoleDescriptionAttribute) as? String
        let enabled = try (optionalAttribute(focused, name: kAXEnabledAttribute) as? NSNumber)?.boolValue
        let editable = try (optionalAttribute(focused, name: "AXEditable") as? NSNumber)?.boolValue
        let readOnly = try (optionalAttribute(focused, name: "AXReadOnly") as? NSNumber)?.boolValue
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        guard result == .success || result == .attributeUnsupported || result == .noValue else {
            throw unavailable("Live editable capability query failed (\(result.rawValue))")
        }
        try validateEditableKeyboardReceiver(
            role: role, description: description, enabled: enabled,
            editable: editable, readOnly: readOnly, valueSettable: result == .success && settable.boolValue,
        )
        return focused
    }

    private static func element(_ source: AXUIElement, attribute: String) throws -> AXUIElement {
        guard let value = try optionalAttribute(source, name: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw unavailable("No live \(attribute) is available")
        }
        // 上面已验证 CF 类型，AX 属性返回值可以转换为对应元素。
        // swiftlint:disable:next force_cast
        return value as! AXUIElement
    }

    private static func optionalAttribute(_ source: AXUIElement, name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(source, name as CFString, &value)
        switch result {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw unavailable("Live keyboard receiver query failed (\(result.rawValue))")
        }
    }

    private static func unavailable(_ reason: String) -> ComputerUseError {
        .stateUnavailable("\(reason). Observe the target and focus its input before typing; no text was sent.")
    }
}

func requireSameKeyboardReceiver(_ expected: AXUIElement, current: AXUIElement) throws {
    guard CFEqual(expected, current) else {
        throw ComputerUseError.stateUnavailable(
            "Keyboard receiver changed. Observe before further input; no keys were sent.",
        )
    }
}

func validateEditableKeyboardReceiver(
    role: String?, description: String?, enabled: Bool?,
    editable: Bool? = nil, readOnly: Bool? = nil, valueSettable: Bool = false,
) throws {
    // AXValue 可写的滑块或复选框不等于文本输入框。
    let textRole = canUseKeyboardTextFallback(role: role, roleDescription: description, isValueSettable: false)
    let editableCombo = role == kAXComboBoxRole && (editable == true || valueSettable)
    guard enabled != false, editable != false, readOnly != true, textRole || editableCombo
    else {
        throw ComputerUseError.stateUnavailable(
            "type_text requires a live focused editable text element. "
                + "Click a text entry area first; no text was sent.",
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
    var readReceiver: (AppSnapshot, Bool) throws -> AXUIElement
    var typeText: (SkyKeyboardTarget, String, () throws -> Void) throws -> Void
    var pressKey: (SkyKeyboardTarget, String, () throws -> Void) throws -> Void

    static var live: KeyboardInputBackend {
        KeyboardInputBackend(
            readReceiver: { try KeyboardReceiver.read(in: $0, requireEditable: $1) },
            typeText: { target, text, validate in
                try SkyKeyboardDispatcher.typeText(target: target, text: text, validateReceiver: validate)
            },
            pressKey: { target, key, validate in
                try SkyKeyboardDispatcher.pressKey(target: target, key: key, validateReceiver: validate)
            },
        )
    }
}
