import ApplicationServices
import Foundation

/// 仅只读依赖；不激活窗口、不发送输入，也不把读取失败解释成没有弹层。
struct AXInputScopeReader<Element> {
    var role: (Element) throws -> String?
    var owner: (Element) throws -> pid_t?
    var parent: (Element) throws -> Element?
    var children: (Element) throws -> [Element]
    var visible: (Element) throws -> Bool?
    var equal: (Element, Element) -> Bool
    var checkDeadline: () throws -> Void = {}
}

let axEditingScopeRoles: Set<String> = ["AXPopover", "AXSheet"]

func axInputPreflightFailure(_ reason: String) -> ComputerUseError {
    .message(
        "AX_INPUT_PREFLIGHT: \(reason). No input was sent by this operation. " +
            "Read fresh state before choosing a target; do not replay earlier input."
    )
}

/// 祖先链既验证进程，也检查循环/截断；无法证明属于当前范围时不能继续写值。
func axInputAncestry<Element>(
    _ element: Element, pid: pid_t, reader: AXInputScopeReader<Element>
) throws -> [Element] {
    var result: [Element] = []
    var current: Element? = element
    for _ in 0 ..< 64 {
        try reader.checkDeadline()
        guard let node = current else { return result }
        guard !result.contains(where: { reader.equal($0, node) }), try reader.owner(node) == pid else {
            throw axInputPreflightFailure("target ancestry changed")
        }
        result.append(node)
        // AXApplication 的父级可能是其他进程的 system-wide 元素。
        let terminalRoles = [kAXApplicationRole as String, kAXWindowRole as String]
        if try terminalRoles.contains(reader.role(node) ?? "") { return result }
        current = try reader.parent(node)
    }
    throw axInputPreflightFailure("target ancestry is incomplete")
}

struct AXEditingScopeObservation<Element> {
    let window: Element
    let observedScopes: [Element]
    let focused: Element?
}

private func attachedAXPath<Element>(
    _ chain: [Element], through ancestor: Element, reader: AXInputScopeReader<Element>
) throws -> Bool {
    guard let end = chain.firstIndex(where: { reader.equal($0, ancestor) }) else { return false }
    for index in 0 ..< end {
        try reader.checkDeadline()
        let children = try reader.children(chain[index + 1])
        guard children.contains(where: { reader.equal($0, chain[index]) }) else { return false }
    }
    try reader.checkDeadline()
    return true
}

private func currentAXScopes<Element>(
    _ observation: AXEditingScopeObservation<Element>, pid: pid_t, reader: AXInputScopeReader<Element>
) throws -> [Element] {
    var scopes = observation.observedScopes
    guard let focused = observation.focused else { return scopes }
    let chain = try axInputAncestry(focused, pid: pid, reader: reader)
    // 其他窗口的编辑弹层不限制指定窗口；同进程多窗口继续可用。
    guard chain.contains(where: { reader.equal($0, observation.window) }) else { return scopes }
    for node in chain where try axEditingScopeRoles.contains(reader.role(node) ?? "") {
        if !scopes.contains(where: { reader.equal($0, node) }) { scopes.append(node) }
    }
    return scopes
}

func validateAXEditingScope<Element>(
    target: Element, observation: AXEditingScopeObservation<Element>, pid: pid_t,
    reader: AXInputScopeReader<Element>
) throws {
    let scopes = try currentAXScopes(observation, pid: pid, reader: reader)
    guard !scopes.isEmpty else { return }
    let targetChain = try axInputAncestry(target, pid: pid, reader: reader)
    for scope in scopes {
        try reader.checkDeadline()
        guard try axEditingScopeRoles.contains(reader.role(scope) ?? "") else {
            throw axInputPreflightFailure("observed editor is no longer valid")
        }
        if try reader.visible(scope) == false { continue }
        // 可见性属性常缺失，必须用实时父子关系确认弹层仍挂接在窗口中。
        let chain = try axInputAncestry(scope, pid: pid, reader: reader)
        guard try attachedAXPath(chain, through: observation.window, reader: reader) else {
            throw axInputPreflightFailure("observed editor detached from its window")
        }
        guard try attachedAXPath(targetChain, through: scope, reader: reader) else {
            throw axInputPreflightFailure(
                "target is outside or detached from the current popover or sheet; " +
                    "inspect that editor instead of its background fields"
            )
        }
    }
}

func validateAXMenuItem<Element>(
    _ element: Element, pid: pid_t, reader: AXInputScopeReader<Element>
) throws {
    try reader.checkDeadline()
    guard try reader.owner(element) == pid,
          try reader.role(element) == kAXMenuItemRole as String,
          try reader.visible(element) != false
    else { throw axInputPreflightFailure("menu item is no longer valid") }
    var child = element
    var seen = [element]
    for _ in 0 ..< 8 {
        try reader.checkDeadline()
        guard let parent = try reader.parent(child),
              !seen.contains(where: { reader.equal($0, parent) }),
              try reader.owner(parent) == pid,
              try reader.visible(parent) != false,
              try reader.children(parent).contains(where: { reader.equal($0, child) })
        else { throw axInputPreflightFailure("menu item is no longer attached to the observed menu") }
        let role = try reader.role(parent)
        if role == kAXMenuRole as String {
            try reader.checkDeadline()
            return
        }
        // 菜单可包含分组，但不能越过窗口或网页去猜另一个菜单。
        guard ["AXGroup", "AXList", "AXScrollArea"].contains(role ?? "") else {
            throw axInputPreflightFailure("menu item parent is no longer a menu")
        }
        seen.append(parent)
        child = parent
    }
    throw axInputPreflightFailure("menu ancestry is incomplete")
}

/// 有界读取后恢复全局默认超时；实际输入仍由 prepareAXInput 独立设置消息超时。
struct AXLiveInputScope {
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.35

    func checkDeadline() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw axInputPreflightFailure("editor validation timed out")
        }
    }

    func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        try checkDeadline()
        // AX 对象没有公开复制 API，探测后恢复默认；不得遗留短超时给实际输入。
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        AXUIElementSetMessagingTimeout(element, Float(max(0.001, min(0.05, remaining))))
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if result == .apiDisabled {
            throw ComputerUseError.permissionDenied("Accessibility permission is required")
        }
        try checkDeadline()
        switch result {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw axInputPreflightFailure("editor could not be read (AX \(result.rawValue))")
        }
    }

    func element(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        guard let value = try value(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    var reader: AXInputScopeReader<AXUIElement> {
        AXInputScopeReader(
            role: { try value($0, kAXRoleAttribute) as? String },
            owner: {
                var pid: pid_t = 0
                let result = AXUIElementGetPid($0, &pid)
                if result == .apiDisabled {
                    throw ComputerUseError.permissionDenied("Accessibility permission is required")
                }
                guard result == .success else { throw axInputPreflightFailure("target owner is unavailable") }
                return pid
            },
            parent: { try element($0, kAXParentAttribute) },
            children: { try value($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] },
            visible: { try value($0, "AXVisible") as? Bool },
            equal: { CFEqual($0, $1) },
            checkDeadline: checkDeadline
        )
    }
}

/// 预检失败不会发送写值；发送后的任何 AX 失败仍然是未知效果，不重试。
func executeAXScopedValueWrite(
    preflight: () throws -> Void, prepare: () -> Void, perform: () -> AXError
) throws {
    try preflight()
    prepare()
    let result = perform()
    guard result == .success else {
        throw ComputerUseError.message(
            "AXUIElementSetAttributeValue failed with \(result.rawValue); effect is unknown. " +
                "Observe before further input; no retry was sent."
        )
    }
}
