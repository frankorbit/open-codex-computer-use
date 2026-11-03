import ApplicationServices
import Foundation

/// 每次观察独立采样；只补充父容器明确列出的成员，不把缺失、截断或不在数组中解释为 false。
struct AXSelectionObservation<Element> {
    private let now: () -> TimeInterval
    private var remainingReadTime: TimeInterval = 0.15
    private var remainingContainers = 32
    private let read: (Element, Int, TimeInterval) -> [Element]?

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        read: @escaping (Element, Int, TimeInterval) -> [Element]?
    ) {
        self.now = now
        self.read = read
    }

    mutating func selectedChildren(of element: Element, role: String?) -> [Element] {
        guard ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXTabGroup", "AXCollection"].contains(role),
              remainingContainers > 0, remainingReadTime > 0 else { return [] }
        remainingContainers -= 1
        let started = now()
        defer { remainingReadTime -= max(0, now() - started) }
        let deadline = started + remainingReadTime
        let members = read(element, 128, deadline)
        guard now() < deadline else { return [] }
        return Array((members ?? []).prefix(128))
    }
}

extension AXSelectionObservation where Element == AXUIElement {
    static func live() -> Self {
        Self { element, limit, deadline in
            func prepareRead() -> Bool {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0, !Task.isCancelled else { return false }
                return true
            }
            guard prepareRead() else { return nil }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, kAXSelectedChildrenAttribute as CFString, &count) ==
                .success,
                count > 0, prepareRead() else { return nil }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(
                element,
                kAXSelectedChildrenAttribute as CFString,
                0,
                min(count, limit),
                &values
            ) == .success,
                let values = values as? [AnyObject], prepareRead() else { return nil }
            guard values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return values as? [AXUIElement]
        }
    }
}

/// 只引用已渲染节点；不为选区额外遍历、创建索引或展开被截断的树。
func renderedSelectionSummary(records: [Int: ElementRecord]) -> [String] {
    let entries = records.values.sorted { $0.index < $1.index }.compactMap { record -> String? in
        guard record.selectionState.selected == true, let rendered = record.renderedDescription else { return nil }
        return "\t" + rendered
    }
    guard !entries.isEmpty else { return [] }
    var remainingCharacters = 8000
    var result = ["", "Selected:"]
    var rendered = 0
    for entry in entries.prefix(64) {
        guard entry.count <= remainingCharacters else { break }
        result.append(entry)
        remainingCharacters -= entry.count
        rendered += 1
    }
    if rendered < entries.count {
        result
            .append(
                "Selected summary truncated: \(entries.count - rendered) additional observed selected nodes; see tree."
            )
    }
    return result
}
