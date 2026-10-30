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

    static func recordAXRead(
        _ failure: HoverPopupAXRead.Failure, attribute: String, pid: pid_t,
        rootID: CGWindowID, remaining: TimeInterval
    ) {
        let stage: String
        let code: Int32
        switch failure {
        case .prepareFailed: stage = "prepareFailed"; code = 0
        case let .copyFailed(error): stage = "copyFailed"; code = error
        case .deadlineExpired: stage = "deadlineExpired"; code = 0
        }
        // 属性名只取固定白名单，不输出 AX 值、标题或正文。
        let allowed = ["AXWindows", "AXMainWindow", "AXFocusedWindow", "AXPosition", "AXSize"]
        let name = allowed.contains(attribute) ? attribute : "other"
        logger.notice("""
        popup_ax_read_failed stage=\(stage, privacy: .public) code=\(code, privacy: .public) \
        attribute=\(name, privacy: .public) pid=\(pid, privacy: .public) root=\(rootID, privacy: .public) \
        remaining_ms=\(remaining * 1000, privacy: .public)
        """)
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

    static func recordRootWindowInfo(rootID: CGWindowID, pid: pid_t, bounds: CGRect, info: [[String: Any]]) {
        let evidence = rootWindowEvidence(rootID: rootID, info: info)
        logger.notice("""
        popup_root_window_evidence id=\(rootID, privacy: .public) pid=\(pid, privacy: .public) \
        expectedBounds=\(String(describing: bounds), privacy: .public) \(evidence, privacy: .public)
        """)
    }

    /// 只解释同一次 CG 枚举里的根窗口记录；未知类型不输出其内容。
    static func rootWindowEvidence(rootID: CGWindowID, info: [[String: Any]]) -> String {
        guard let record = info.first(where: {
            guard let id = $0[kCGWindowNumber as String] as? NSNumber,
                  CFGetTypeID(id) != CFBooleanGetTypeID() else { return false }
            return id.doubleValue == Double(rootID)
        }) else { return "stage=recordMissing recordCount=\(info.count)" }
        let parsed = HoverPopupObservation.windowInfo(record)
        let stage = parsed == nil ? "recordRejected" : (parsed?.isVisible == true ? "visible" : "notVisible")
        func number(_ key: CFString) -> String {
            guard let value = record[key as String] else { return "missing" }
            guard let value = value as? NSNumber else { return "unsupported" }
            let kind = CFGetTypeID(value) == CFBooleanGetTypeID() ? "bool" : "number"
            return "\(kind):\(value.doubleValue)"
        }
        let bounds = (record[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) }
        return "stage=\(stage) recordCount=\(info.count) pid=\(number(kCGWindowOwnerPID)) "
            + "alpha=\(number(kCGWindowAlpha)) onscreen=\(number(kCGWindowIsOnscreen)) "
            + "layer=\(number(kCGWindowLayer)) bounds=\(bounds.map { String(describing: $0) } ?? "invalid")"
    }
}
