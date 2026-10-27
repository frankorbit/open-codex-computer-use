import ApplicationServices

/// 文稿身份来自窗口的 AXDocument，不靠打开重命名/移动面板推断路径。
func formattedURLSegment(role: String?, title: String?, label: String?, readURL: (String) -> String?) -> String {
    let attribute: String
    switch role {
    case "AXWindow": attribute = kAXDocumentAttribute
    case "AXWebArea": attribute = kAXURLAttribute
    default: return ""
    }
    guard let url = readURL(attribute), !url.isEmpty, url != title, url != label else {
        return ""
    }

    return ", URL: \(url)"
}
