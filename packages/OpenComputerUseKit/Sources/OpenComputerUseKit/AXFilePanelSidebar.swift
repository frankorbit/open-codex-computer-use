import ApplicationServices

/// 仅使用系统文件面板的明确标识，不按标题、应用名称或任意 outline 猜测。
func isNativeFilePanel(role: String?, identifier: String?) -> Bool {
    [kAXWindowRole as String, kAXSheetRole as String].contains(role ?? "")
        && ["open-panel", "save-panel"].contains(identifier ?? "")
}

struct AXFilePanelSidebarObservation<Element> {
    let row: Element
    let outline: Element
    let panel: Element
    let window: Element
}

/// setter 前重新确认面板身份及每一级父子关系，不能用旧快照授权已脱离的侧栏。
func validateAXFilePanelSidebar<Element>(
    _ observation: AXFilePanelSidebarObservation<Element>, pid: pid_t,
    reader: AXInputScopeReader<Element>, identifier: (Element) throws -> String?
) throws {
    let row = observation.row
    let outline = observation.outline
    let panel = observation.panel
    let window = observation.window
    try reader.checkDeadline()
    guard try isNativeFilePanel(role: reader.role(panel), identifier: identifier(panel)),
          try reader.visible(panel) != false,
          try reader.role(row) == kAXRowRole as String,
          try reader.role(outline) == kAXOutlineRole as String
    else { throw axInputPreflightFailure("file panel sidebar scope changed") }
    let chain = try axInputAncestry(row, pid: pid, reader: reader)
    guard chain.count > 1, reader.equal(chain[1], outline),
          let panelIndex = chain.firstIndex(where: { reader.equal($0, panel) }),
          let windowIndex = chain.firstIndex(where: { reader.equal($0, window) }),
          panelIndex > 1, panelIndex <= windowIndex
    else { throw axInputPreflightFailure("file panel sidebar left its bound window") }
    for index in 0 ..< windowIndex {
        try reader.checkDeadline()
        guard try reader.role(chain[index]) != "AXWebArea",
              try reader.visible(chain[index]) != false,
              try reader.children(chain[index + 1]).contains(where: { reader.equal($0, chain[index]) })
        else {
            throw axInputPreflightFailure("file panel sidebar detached before selection")
        }
    }
    try reader.checkDeadline()
}

/// 与侧栏能力检查共享同一 deadline；校验完成后才准备单次输入。
func prepareAXFilePanelSidebar(
    row: AXUIElement, outline: AXUIElement, snapshot: AppSnapshot, probe: AXLiveInputScope
) throws {
    let panels = snapshot.elements.values.filter {
        isNativeFilePanel(role: $0.role, identifier: $0.identifier) && $0.element != nil
    }
    guard panels.count == 1, let panel = panels.first?.element else {
        throw axInputPreflightFailure("file panel sidebar scope is ambiguous")
    }
    guard let window = snapshot.windowElement else {
        throw axInputPreflightFailure("file panel bound window is missing")
    }
    var reader = probe.reader
    reader.owner = { element in
        let (result, owner) = try probe.sidebarOwner(element)
        if result == .apiDisabled {
            throw ComputerUseError.permissionDenied("Accessibility permission is required")
        }
        guard result == .success else {
            throw axInputPreflightFailure("file panel owner is unavailable")
        }
        return owner
    }
    try validateAXFilePanelSidebar(
        .init(row: row, outline: outline, panel: panel, window: window), pid: snapshot.app.pid,
        reader: reader, identifier: { try probe.value($0, kAXIdentifierAttribute) as? String }
    )
    guard try isFinderSidebarOutline(
        identifier: probe.value(outline, kAXIdentifierAttribute) as? String,
        description: probe.value(outline, kAXDescriptionAttribute) as? String
    ) else { throw axInputPreflightFailure("file panel sidebar identity changed") }
    try probe.checkDeadline()
    prepareAXInput(outline)
}
