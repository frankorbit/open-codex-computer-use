import ApplicationServices

struct AXListSelectionReader<Element> {
    let parent: (Element) -> Element?
    let role: (Element) -> String?
    let selectionCapability: (Element) -> (AXError, Bool)
}

/// 只在发送前允许判定选择能力不可用；发送后的任何失败都必须终止，不能继续 AXOpen 或鼠标回退。
func selectNativeListItem<Element>(
    containing element: Element,
    opensItem: Bool,
    reader: AXListSelectionReader<Element>,
    prepare: (Element) -> Void,
    select: (Element, Element) -> AXError
) throws -> Bool {
    var current = element
    for _ in 0 ..< 8 {
        guard let container = reader.parent(current) else { return false }
        if reader.role(container) == "AXWebArea" { return false }
        if reader.role(container) == kAXListRole as String {
            let (error, settable) = reader.selectionCapability(container)
            guard error == .success, settable else {
                // 文件项的“打开”不是“选中”；能力消失时不能改变动作语义。
                if opensItem || (error != .success && error != .attributeUnsupported) {
                    throw ComputerUseError.stateUnavailable(
                        "Native list selection is unavailable (AX \(error.rawValue)); no input sent; observe again"
                    )
                }
                // 普通内层列表没有选择能力时，保留原来向外层可选择列表查找的行为。
                current = container
                continue
            }
            prepare(container)
            let result = select(container, current)
            guard result == .success else {
                throw ComputerUseError.message(
                    "AXUIElementSetAttributeValue(AXSelectedChildren) failed with \(result.rawValue); "
                        + "selection was attempted; do not replay or fall back to Open"
                )
            }
            return true
        }
        current = container
    }
    return false
}
