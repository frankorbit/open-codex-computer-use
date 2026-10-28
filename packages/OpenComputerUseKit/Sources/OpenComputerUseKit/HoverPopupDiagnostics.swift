import CoreGraphics
import OSLog

/// 只记录固定阶段码，不记录窗口标题、AX 文本、图片或输入凭证。
enum HoverPopupDiagnostics {
    enum Reason: String {
        case snapshotRootMissing, workerBusy, deadlineExpired
        case windowListUnavailable, rootNotOnScreen, rootGeometryChanged
        case axStateUnavailable, axWindowsUnavailable, axWindowLimit
        case axTimeoutSetup, axExclusionUnavailable, axRootMissing, axRootOwnerMismatch
        case applicationUnavailable, imageUnavailable, incompleteCapture
    }

    private static let logger = Logger(subsystem: "ai.today.ocu", category: "popup")

    static func record(_ reason: Reason) {
        logger.notice("popup_observation_incomplete reason=\(reason.rawValue, privacy: .public)")
    }

    static func recordRootFrame(expected: CGRect, observed: CGRect?) {
        // 复用本次读取的结果；不为诊断再次查询 AX 或延长预算。
        let actual = observed.map { String(describing: $0) } ?? "unavailable"
        logger.notice("""
        popup_observation_incomplete reason=axRootFrameUnverified \
        expected=\(String(describing: expected), privacy: .public) observed=\(actual, privacy: .public)
        """)
    }
}
