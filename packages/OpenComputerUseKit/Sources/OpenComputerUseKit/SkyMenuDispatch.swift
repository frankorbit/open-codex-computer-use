enum SkyPasteRoute: String {
    case menuEquivalent = "menu_equivalent"
    case focusedText = "focused_text"

    static func forApplication(bundleIdentifier: String?) -> Self {
        bundleIdentifier == "com.apple.finder" ? .focusedText : .menuEquivalent
    }
}

/// 查找可能跨多次 AX IPC；两种提交路径都必须在查找结束后复验接收者。
func dispatchSkyMenuKey<Item>(
    useMenuEquivalent: Bool = true,
    findMenuItem: () throws -> Item?,
    validateReceiver: () throws -> Void,
    pressMenuItem: (Item) throws -> Void,
    postKey: () throws -> Void,
) throws {
    try validateReceiver()
    let item = try useMenuEquivalent ? findMenuItem() : nil
    try validateReceiver()
    if let item {
        // 一旦尝试 AXPress，任何错误都向上传递，不能换路重放。
        try pressMenuItem(item)
    } else {
        try postKey()
    }
}
