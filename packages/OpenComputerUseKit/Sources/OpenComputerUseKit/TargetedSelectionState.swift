import CoreFoundation
import Foundation

/// 只保留 AX 实际返回的选择证据；属性缺失或读取错误不能当作 false。
struct TargetedSelectionState {
    var selected: Bool?
    var markCharacter: String?

    init(selected: AnyObject? = nil, markCharacter: AnyObject? = nil) {
        if let selected, CFGetTypeID(selected) == CFBooleanGetTypeID() {
            self.selected = (selected as? NSNumber)?.boolValue
        }
        // 菜单标记通常是一个字符；按查询文本预算限制异常长的应用数据。
        self.markCharacter = (markCharacter as? String).map { String($0.prefix(1000)) }
    }

    func append(to dictionary: inout [String: Any]) {
        if let selected { dictionary["selected"] = selected }
        if let markCharacter { dictionary["mark_character"] = markCharacter }
    }
}
