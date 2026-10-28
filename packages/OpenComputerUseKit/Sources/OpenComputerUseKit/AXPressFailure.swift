import Foundation

/// 仅普通原始按钮的一次 AXPress 返回通用 failure；权限、超时等错误不进入此分支。
struct AXPressFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }

    func result(observe: () throws -> [ToolResultContentItem]) -> ToolCallResult {
        let error = ToolResultContentItem(dictionary: [
            "type": "text", "text": message,
            "_meta": ["ocuFailedPress": ["version": 1, "axCode": -25200, "effect": "unknown"]]
        ])
        var content = [error, .text(
            "Post-error observation is diagnostic only. The original action remains an error with unknown effect. "
                + "Stop input; do not retry or use these indices for input. A new explicit observation is required."
        )]
        do {
            content += try observe()
        } catch { content.append(.text("Post-error observation failed: \(error.localizedDescription). "
                + "Original action error is unchanged; stop input.")) }
        return ToolCallResult(content: content, isError: true)
    }
}
