import ApplicationServices

struct AXFocusedPathReader<Element> {
    var owner: (Element) -> pid_t?
    var parent: (Element) -> Element?
    var equal: (Element, Element) -> Bool
}

/// 仅为观察保留焦点路径；必须回溯到当前绑定根，不能展开其他窗口的行。
func focusedAncestorPath<Element>(
    focused: Element?, root: Element, pid: pid_t, maximumDepth: Int,
    reader: AXFocusedPathReader<Element>
) -> [Element] {
    guard maximumDepth > 0 else { return [] }
    var path: [Element] = []
    var current = focused
    for _ in 0 ..< maximumDepth {
        guard let element = current, reader.owner(element) == pid,
              !path.contains(where: { reader.equal($0, element) }) else { return [] }
        path.append(element)
        if reader.equal(element, root) { return path }
        current = reader.parent(element)
    }
    return []
}

func shouldSummarizeAXRow<Element>(
    role: String, selected: Bool, element: Element, focusedPath: [Element],
    equal: (Element, Element) -> Bool
) -> Bool {
    role == kAXRowRole as String && !selected && !focusedPath.contains(where: { equal($0, element) })
}
