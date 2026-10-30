import ApplicationServices
import OSLog

/// 主窗选择只复用原读取结果采证，不额外查询窗口、改超时或恢复应用。
enum WindowSelectionDiagnostics {
    enum Stage: String {
        case focusedWindowUnavailable, captureUnavailable
    }

    private static let logger = Logger(subsystem: "ai.today.ocu", category: "window-selection")

    static func record(_ stage: Stage, pid: pid_t) {
        logger.notice("window_selection_failed stage=\(stage.rawValue, privacy: .public) pid=\(pid, privacy: .public)")
    }

    static func read(
        attribute: String,
        copy: (inout CFTypeRef?) -> AXError,
        report: (String, Int32, Bool) -> Void = recordRead
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = copy(&value)
        guard error == .success, let value else {
            // 仅白名单属性；不记录查询值、标题、输入内容或任意属性名。
            if [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute].contains(attribute) {
                report(attribute, error.rawValue, value != nil)
            }
            return nil
        }
        return value
    }

    private static func recordRead(attribute: String, code: Int32, hasValue: Bool) {
        logger.notice("""
        window_selection_ax_read_failed attribute=\(attribute, privacy: .public) \
        code=\(code, privacy: .public) returned_value=\(hasValue, privacy: .public)
        """)
    }
}
