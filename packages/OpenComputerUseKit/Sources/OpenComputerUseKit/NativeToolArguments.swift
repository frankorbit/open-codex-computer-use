import Foundation

/// 校验只读工具定义，不依赖当前是否展示 hover，也不授予任何执行权限。
func validateNativeToolArguments(name: String, arguments: [String: Any]) throws {
    guard let definition = (ToolDefinitions.all + [ToolDefinitions.hover]).first(where: { $0.name == name }),
          let properties = definition.inputSchema["properties"] as? [String: [String: Any]]
    else {
        throw ComputerUseError.unsupportedTool(name)
    }
    guard Set(arguments.keys).isSubset(of: Set(properties.keys)) else {
        // 不回显任意字段名或值，避免将用户内容写进错误和日志。
        throw ComputerUseError.invalidArguments(
            "Unsupported options. Allowed fields: \(properties.keys.sorted().joined(separator: ", ")). "
                + "Keyboard shortcuts use key: 'super+s', not a modifiers option. No input was sent."
        )
    }
    for key in definition.inputSchema["required"] as? [String] ?? [] {
        guard let value = arguments[key], (value as? String)?.isEmpty != true else {
            throw ComputerUseError.missingArgument(key)
        }
    }
    for key in arguments.keys.sorted() {
        guard let value = arguments[key], let property = properties[key] else { continue }
        try validateNativeToolValue(value, key: key, property: property)
    }
    if name == "click", arguments["popup_token"] == nil {
        let hasElement = arguments["element_index"] != nil
        let hasPoint = arguments["x"] != nil && arguments["y"] != nil
        guard hasElement != hasPoint,
              hasElement ? (arguments["x"] == nil && arguments["y"] == nil) : hasPoint
        else {
            throw ComputerUseError.invalidArguments("click requires either element_index or both x/y, never both")
        }
    }
}

private func validateNativeToolValue(_ value: Any, key: String, property: [String: Any]) throws {
    // JS 适配器长期以整数传索引；保持既有字符串/整数双入口。
    if key == "element_index" {
        guard normalizedElementIndexArgument(value) != nil else {
            throw ComputerUseError.invalidArguments("element_index must be a nonempty string or an integer")
        }
        return
    }
    if key == "text_limit" {
        if let text = value as? String, text.lowercased() == SnapshotTextLimit.maxKeyword { return }
        guard try nativeToolInteger(value, key: key) > 0 else {
            throw ComputerUseError.invalidArguments("text_limit must be a positive integer or max")
        }
        return
    }
    try validateNativeToolSchemaValue(value, key: key, property: property)
}

private func validateNativeToolSchemaValue(_ value: Any, key: String, property: [String: Any]) throws {
    switch property["type"] as? String {
    case "string":
        guard let string = value as? String else {
            throw ComputerUseError.invalidArguments("\(key) must be a string")
        }
        if let choices = property["enum"] as? [String],
           !choices.contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            throw ComputerUseError.invalidArguments("\(key) must be one of: \(choices.joined(separator: ", "))")
        }
    case "boolean":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ComputerUseError.invalidArguments("\(key) must be a boolean")
        }
        if let expected = property["const"] as? Bool, number.boolValue != expected {
            throw ComputerUseError.invalidArguments("\(key) must be \(expected)")
        }
    case "number":
        _ = try nativeToolNumber(value, key: key)
    case "integer":
        let integer = try nativeToolInteger(value, key: key)
        let minimum = property["minimum"] as? Int ?? Int.min
        let maximum = property["maximum"] as? Int ?? Int.max
        guard integer >= minimum, integer <= maximum else {
            throw ComputerUseError.invalidArguments("\(key) is outside the supported integer range")
        }
    default:
        throw ComputerUseError.invalidArguments("Unsupported argument schema")
    }
}

private func nativeToolNumber(_ value: Any, key: String) throws -> Double {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite
    else {
        throw ComputerUseError.invalidArguments("\(key) must be a finite number")
    }
    return number.doubleValue
}

func nativeToolInteger(_ value: Any, key: String) throws -> Int {
    let number = try nativeToolNumber(value, key: key)
    // 先保留精确 Int；Double(Int.max) 已向上舍入，不能再用 <= 判断后强转。
    if let integer = value as? Int { return integer }
    guard let integer = Int(exactly: number) else {
        throw ComputerUseError.invalidArguments("\(key) must be an integer within the supported range")
    }
    return integer
}
