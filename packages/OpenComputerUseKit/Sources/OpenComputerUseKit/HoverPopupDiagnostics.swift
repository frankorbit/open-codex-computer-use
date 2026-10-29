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
        case candidateLimit, candidateChangedAfterCapture, candidateChangedBeforeReturn
        case imageCaptureFailed, imageDataInvalid
    }

    private static let logger = Logger(subsystem: "ai.today.ocu", category: "popup")

    static func record(_ reason: Reason) {
        logger.notice("popup_observation_incomplete reason=\(reason.rawValue, privacy: .public)")
    }

    /// 只复用本轮已有窗口元数据，不重新查询、不记录标题或图片。
    static func recordCandidate(
        _ reason: Reason, expected: HoverPopupObservation.Window?, observed: HoverPopupObservation.Window?
    ) {
        func description(_ window: HoverPopupObservation.Window?) -> String {
            guard let window else { return "unavailable" }
            return "id=\(window.windowID),pid=\(window.pid),bounds=\(window.bounds),"
                + "alpha=\(window.alpha),onscreen=\(window.isOnscreen),layer=\(window.layer)"
        }
        logger.notice("""
        popup_observation_incomplete reason=\(reason.rawValue, privacy: .public) \
        expected=\(description(expected), privacy: .public) observed=\(description(observed), privacy: .public)
        """)
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
