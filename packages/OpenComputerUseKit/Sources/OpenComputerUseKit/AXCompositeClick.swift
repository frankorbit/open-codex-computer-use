import CoreGraphics
import Foundation

let compositeClickRoles: Set<String> = ["AXRow", "AXCell", "AXGroup"]

/// Help 是控件动作说明，不把用户写在标题/备注里的“完成”解释成操作语义。
func axHelpDescribesCompletionToggle(_ help: String?) -> Bool {
    guard let text = help?.lowercased() else { return false }
    return text.contains("to mark as completed") || text.contains("to mark as incomplete")
        || text.contains("mark this reminder as completed") || text.contains("mark this reminder as incomplete")
        || text.contains("标记为已完成") || text.contains("标记为未完成")
}

/// 整行的默认动作可能是完成事项，不能当作选择/打开。仅拒绝歧义目标，明确的按钮/勾选框仍可操作。
func validateAXCompositeClick(
    _ target: ElementRecord,
    button: MouseButtonKind,
    children: (ElementRecord, Int) throws -> [ElementRecord]
) throws {
    guard button == .left, compositeClickRoles.contains(target.role ?? "") else { return }
    var level = [target]
    var remaining = 32
    for depth in 0 ..< 3 {
        var next: [ElementRecord] = []
        for node in level {
            guard !axHelpDescribesCompletionToggle(node.help) else {
                throw axInputPreflightFailure(
                    "composite row/cell has a completion-toggle action; it is not an unambiguous open/select target"
                )
            }
            guard depth < 2, remaining > 0 else { continue }
            let candidates = try Array(children(node, remaining).prefix(remaining))
            remaining -= candidates.count
            for child in candidates {
                guard compositeClickRoles.contains(child.role ?? ""),
                      let parentFrame = node.localFrame, let frame = child.localFrame,
                      !parentFrame.isEmpty, !frame.isEmpty,
                      frame.intersection(parentFrame).width >= parentFrame.width * 0.8,
                      frame.intersection(parentFrame).height >= parentFrame.height * 0.8 else { continue }
                next.append(child)
            }
        }
        // 有界检查；这里只识别已知歧义，不把没有 Help 当作安全意图证明。
        level = Array(next.prefix(32))
    }
}
