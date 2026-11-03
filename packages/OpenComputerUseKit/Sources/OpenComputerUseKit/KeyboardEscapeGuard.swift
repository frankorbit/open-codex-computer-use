import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// 观察到菜单不代表 PID 键盘事件由菜单接收；不能让关闭菜单的 Escape 落入文稿编辑者。
enum KeyboardEscapeGuard {
    static func isPlainEscape(_ key: String) throws -> Bool {
        let parsed = try KeyPressParser.parse(key)
        return parsed.keyCode == CGKeyCode(kVK_Escape) && parsed.modifiers.isEmpty
    }

    static func hasObservedMenu(_ snapshot: AppSnapshot) -> Bool {
        snapshot.elements.values.contains { record in
            record.role == kAXMenuRole as String || record.role == kAXMenuItemRole as String
                || (record.role == kAXMenuBarItemRole as String
                    && (record.selectionState.selected == true || record.selectionState.selectedByParent))
        }
    }

    static func validate(
        in snapshot: AppSnapshot,
        reader: KeyboardReceiverAXReader = KeyboardReceiverAXReader()
    ) throws {
        guard hasObservedMenu(snapshot) else { return }
        let app = AXUIElementCreateApplication(snapshot.app.pid)
        let focused = try reader.element(app, attribute: kAXFocusedUIElementAttribute)
        var owner: pid_t = 0
        guard AXUIElementGetPid(focused, &owner) == .success, owner == snapshot.app.pid else {
            throw axInputPreflightFailure("Escape menu receiver ownership is unknown")
        }
        let role = try reader.value(focused, attribute: kAXRoleAttribute) as? String
        try validateFocusedRole(role)
    }

    static func validateFocusedRole(_ role: String?) throws {
        // menubar item 的 selected 只是打开意图/观察证据，不等于菜单获得键盘焦点。
        guard role == kAXMenuRole as String || role == kAXMenuItemRole as String else {
            throw axInputPreflightFailure(
                "Escape cannot dismiss an observed menu without live menu focus; " +
                    "it may cancel edits in the underlying document. Preserve the editor; " +
                    "do not retry Escape, switch routes or borrow an editor's Cancel action"
            )
        }
    }
}
