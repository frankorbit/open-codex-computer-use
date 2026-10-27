import ApplicationServices

struct AXSidebarSelectionReader<Element> {
    // nil 只表示已确认属性不存在；权限、陈旧对象及读取失败必须抛出。
    let parent: (Element) throws -> Element?
    let role: (Element) throws -> String?
    let isSidebar: (Element) throws -> Bool
    /// 调用方可在能力读取前后检查 deadline；抛出的错误不得降级为不可选择。
    let selectionCapability: (Element, String) throws -> (AXError, Bool)
}

/// 调用方仅传入原始左键单击、非 Web 目标；不沿标签或后代候选推断行点击意图。
func selectFinderSidebarRow<Element>(
    _ row: Element,
    bundleIdentifier: String?,
    reader: AXSidebarSelectionReader<Element>,
    prepare: (Element) throws -> Void,
    select: (Element, [Element]) -> AXError
) throws -> Bool {
    guard bundleIdentifier == "com.apple.finder",
          try reader.role(row) == kAXRowRole as String,
          let outline = try reader.parent(row),
          try reader.role(outline) == kAXOutlineRole as String,
          try reader.isSidebar(outline) else { return false }

    let (rowError, rowSettable) = try reader.selectionCapability(row, kAXSelectedAttribute as String)
    InputDiagnostics.event("sidebar_row_capability", [
        "ax_result": String(rowError.rawValue), "settable": String(rowSettable)
    ])
    if rowError == .apiDisabled {
        throw ComputerUseError.permissionDenied(
            "Accessibility permission is required (AX \(rowError.rawValue)); "
                + "no further input was sent; do not replay the previous action"
        )
    }
    // 保守排除标题行；容器可选择并不保证行自身的 AXSelected 可写。
    if rowError == .attributeUnsupported { return false }
    guard rowError == .success else {
        throw ComputerUseError.stateUnavailable(
            "Finder sidebar row selection capability failed (AX \(rowError.rawValue)); "
                + "no further input was sent; do not replay the previous action"
        )
    }
    guard rowSettable else { return false }

    let (outlineError, outlineSettable) = try reader.selectionCapability(outline, kAXSelectedRowsAttribute as String)
    InputDiagnostics.event("sidebar_outline_capability", [
        "ax_result": String(outlineError.rawValue), "settable": String(outlineSettable)
    ])
    if outlineError == .apiDisabled {
        throw ComputerUseError.permissionDenied(
            "Accessibility permission is required (AX \(outlineError.rawValue)); "
                + "no further input was sent; do not replay the previous action"
        )
    }
    // 已确认是可选择的侧栏行，不能因容器能力缺失而改成打开或鼠标输入。
    guard outlineError == .success, outlineSettable else {
        throw ComputerUseError.stateUnavailable(
            "Finder sidebar AXSelectedRows is unavailable (AX \(outlineError.rawValue)); "
                + "no further input was sent; do not replay the previous action"
        )
    }

    try prepare(outline)
    let result = select(outline, [row])
    // setter 已发送；任何错误均终止，不能换属性、AX action 或鼠标路线。
    guard result == .success else {
        throw ComputerUseError.message(
            "AXUIElementSetAttributeValue(AXSelectedRows) failed with \(result.rawValue); "
                + "selection was attempted; do not replay or fall back to AXOpen or mouse input"
        )
    }
    return true
}

func isFinderSidebarOutline(identifier: String?, description: String?) -> Bool {
    identifier == "sidebar" || description == "sidebar"
}
