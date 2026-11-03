import AppKit
import ApplicationServices

/// 仅原生菜单栏入口需要文稿 key 状态；菜单命令与普通 AX 控件不经过此路径。
struct AXMenuBarFocusBackend {
    var foregroundPID: () -> pid_t?
    var validate: (ElementRecord, AppSnapshot) throws -> Void
    var prepare: (AppSnapshot, () throws -> Void) throws -> Void
    var isAvailable: () -> Bool = { true }

    static var live: Self {
        Self(
            foregroundPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            validate: { try AXMenuBarFocus.validate($0, in: $1) },
            prepare: { snapshot, submit in
                guard let bounds = snapshot.windowBounds, let windowID = snapshot.targetWindowID else {
                    throw axInputPreflightFailure("Menu opener has no bound document window")
                }
                // 这里只借用既有焦点生命周期，不构造或发送鼠标事件。
                let target = SkyClickTarget(
                    screenPoint: CGPoint(x: bounds.midX, y: bounds.midY),
                    windowPoint: CGPoint(x: bounds.width / 2, y: bounds.height / 2),
                    windowBounds: bounds, windowID: windowID, pid: snapshot.app.pid
                )
                let focus = SkyClickMenuFocus.current ?? SkyClickMenuFocus(retainsMenus: false)
                try focus.deliver(target: target, profile: .standard, button: .left, clickCount: 1, submit: submit)
            },
            isAvailable: { SkyLightSPI.shared.capability.isAvailable }
        )
    }
}

enum AXMenuBarFocus {
    static func applies(
        record: ElementRecord, snapshot: AppSnapshot, button: MouseButtonKind,
        clickCount: Int, foregroundPID: pid_t?
    ) -> Bool {
        record.role == kAXMenuBarItemRole as String && button == .left && clickCount == 1
            && record.rawActions.contains { $0.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame }
            && foregroundPID != snapshot.app.pid && !KeyboardEscapeGuard.hasObservedMenu(snapshot)
    }

    static func dispatch(
        record: ElementRecord, snapshot: AppSnapshot, backend: AXMenuBarFocusBackend,
        submit: () throws -> Void
    ) throws {
        // 与后台鼠标及菜单到期清理共享锁；准备后失败也不能进入其他点击路线。
        try SkyClickDispatcher.synchronized {
            try backend.validate(record, snapshot)
            try backend.prepare(snapshot) {
                try backend.validate(record, snapshot)
                try Task.checkCancellation()
                InputDiagnostics.event("menu_bar_focus_prepared", ["target_pid": String(snapshot.app.pid)])
                try submit()
            }
        }
    }

    static func validate(
        _ record: ElementRecord, in snapshot: AppSnapshot,
        reader: KeyboardReceiverAXReader = KeyboardReceiverAXReader()
    ) throws {
        try Task.checkCancellation()
        try KeyboardReceiver.validateWindow(in: snapshot)
        guard
            let element = record.element, let bounds = snapshot.windowBounds,
            let windowID = snapshot.targetWindowID,
            let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
            rows.compactMap(HoverPopupObservation.windowInfo).contains(where: {
                $0.pid == snapshot.app.pid && $0.windowID == windowID && $0.bounds == bounds
            })
        else {
            throw axInputPreflightFailure("Menu document window changed")
        }
        try validateOpener(element, pid: snapshot.app.pid, reader: reader)
        // 已知其他窗口接收输入时拒绝；不通过设置 AXFocusedWindow 强行改写接收者。
        let focusedWindowMatches = try KeyboardReceiver.optionalFocusedWindowMatches(in: snapshot)
        try validateCoordinateAppPostReceiver(focusedWindowMatches: focusedWindowMatches)
    }

    static func validateOpener(_ element: AXUIElement, pid: pid_t, reader: KeyboardReceiverAXReader) throws {
        let app = AXUIElementCreateApplication(pid)
        let bar = try reader.element(app, attribute: kAXMenuBarAttribute)
        let parent = try reader.element(element, attribute: kAXParentAttribute)
        var owner: pid_t = 0
        guard
            AXUIElementGetPid(element, &owner) == .success, owner == pid,
            CFEqual(parent, bar),
            try reader.value(element, attribute: kAXRoleAttribute) as? String == kAXMenuBarItemRole,
            try reader.value(bar, attribute: kAXRoleAttribute) as? String == kAXMenuBarRole,
            try (reader.value(element, attribute: kAXEnabledAttribute) as? NSNumber)?.boolValue == true
        else { throw axInputPreflightFailure("Menu opener is not an enabled native menu bar item") }

        let children = try reader.value(bar, attribute: kAXChildrenAttribute) as? [AXUIElement]
        let selected = try reader.value(bar, attribute: kAXSelectedChildrenAttribute) as? [AXUIElement]
        guard
            let children, let selected,
            children.contains(where: { CFEqual($0, element) }), selected.isEmpty,
            try (reader.value(element, attribute: kAXSelectedAttribute) as? NSNumber)?.boolValue != true
        else { throw axInputPreflightFailure("Menu state changed; observe without reopening it") }
    }
}
