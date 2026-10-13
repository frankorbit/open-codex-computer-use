import AppKit
import ApplicationServices
import Foundation
import ImageIO

struct VisualCursorTarget: Equatable {
    let point: CGPoint
    let window: CursorTargetWindow?
}

public enum ClickMethod: String, CaseIterable, Sendable {
    case auto
    case accessibility
    case appPost = "app_post"
    case skyClick = "sky_click"
    case global
}

func parseClickMethod(_ rawValue: String?) throws -> ClickMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ClickMethod.auto.rawValue

    guard let method = ClickMethod(rawValue: normalized) else {
        let expected = ClickMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid click_method '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return method
}

func validateClickMethod(
    _ method: ClickMethod,
    hasElementIndex: Bool,
    environment: [String: String]
) throws {
    let policy = try ExecutionPolicy.current(environment: environment)
    if method == .global { try policy.requireForeground("Global click") }
    if method == .accessibility, !hasElementIndex {
        throw ComputerUseError.message("click_method 'accessibility' requires element_index")
    }

    if method == .global, !foregroundClicksEnabled(environment: environment) {
        throw ComputerUseError.message(
            "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_FOREGROUND_CLICKS=1, OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE=foreground or OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it moves the system pointer and changes foreground focus"
        )
    }
}

public enum KeyMethod: String, CaseIterable, Sendable {
    case auto
    case skyKey = "sky_key"
}

func parseKeyMethod(_ rawValue: String?) throws -> KeyMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? KeyMethod.auto.rawValue

    guard let method = KeyMethod(rawValue: normalized) else {
        let expected = KeyMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid key_method '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return method
}

func validateSkyClickArguments(
    method: ClickMethod,
    mouseButton: String,
    clickCount: Int
) throws {
    guard method == .skyClick else {
        return
    }

    let normalized = mouseButton.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized == "left" || normalized == "right" else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports mouse_button 'left' or 'right'"
        )
    }

    if normalized == "right", clickCount != 1 {
        throw ComputerUseError.invalidArguments("sky_click right button requires click_count 1")
    }
    guard (1...2).contains(clickCount) else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports click_count 1 or 2"
        )
    }
}

struct VisualCursorScreenMapping: Equatable {
    let screenStateFrame: CGRect
    let appKitFrame: CGRect
}

func currentVisualCursorScreenMappings() -> [VisualCursorScreenMapping] {
    NSScreen.screens.compactMap { screen in
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return VisualCursorScreenMapping(
            screenStateFrame: CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value)),
            appKitFrame: screen.frame
        )
    }
}

func screenStatePointToAppKitGlobalPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    guard let mapping = screenMappings.first(where: { $0.screenStateFrame.contains(point) }) else {
        return point
    }

    let localX = point.x - mapping.screenStateFrame.minX
    let localY = point.y - mapping.screenStateFrame.minY

    return CGPoint(
        x: mapping.appKitFrame.minX + localX,
        y: mapping.appKitFrame.maxY - localY
    )
}

func visualCursorAppKitPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    screenStatePointToAppKitGlobalPoint(
        fromScreenStatePoint: point,
        screenMappings: screenMappings
    )
}

func inputEventPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    point
}

func makeVisualCursorTarget(
    at point: CGPoint,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorTarget {
    VisualCursorTarget(
        point: screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: point,
            screenMappings: screenMappings
        ),
        window: targetWindowID.map { CursorTargetWindow(windowID: $0, layer: targetWindowLayer ?? 0) }
    )
}

func makeVisualCursorTarget(
    localFrame: CGRect?,
    windowBounds: CGRect?,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorTarget? {
    guard let localFrame, let windowBounds else {
        return nil
    }

    let point = CGPoint(
        x: windowBounds.minX + localFrame.midX,
        y: windowBounds.minY + localFrame.midY
    )
    return makeVisualCursorTarget(
        at: point,
        targetWindowID: targetWindowID,
        targetWindowLayer: targetWindowLayer,
        screenMappings: screenMappings
    )
}

func inputFallbackDebugEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

func globalPointerFallbacksEnabled(environment: [String: String]) -> Bool {
    guard (try? ExecutionPolicy.current(environment: environment)) == .compatible else { return false }
    guard let rawValue = environment["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

/// Whether an action's result reads the window back (settle, then a full snapshot).
/// A program driving the tools (the `js` REPL adapter) reads state explicitly and
/// sets `OPEN_COMPUTER_USE_ACTION_READ_BACK=0`, so its actions return a short status.
func actionReadBackEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_ACTION_READ_BACK"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return true
    }

    return !["0", "false", "no", "off"].contains(rawValue)
}

/// How a `drag` is delivered. `drag` has no method argument; the path is decided
/// by the same process-level gate that authorizes `click_method=global`.
enum DragDeliveryPath: String, CaseIterable {
    /// `CGEvent.postToPid`: never moves the system pointer, but the events do not
    /// pass through the window server, so window-server drag sessions (window
    /// moves, text selection, Finder drag-and-drop) are not driven.
    case appPost = "app_post"
    /// `.cghidEventTap`: drives window-server drag sessions and may move the
    /// real pointer or change foreground focus.
    case global
}

func dragDeliveryPath(environment: [String: String]) -> DragDeliveryPath {
    globalPointerFallbacksEnabled(environment: environment) ? .global : .appPost
}

func dragDeliveryNote(for path: DragDeliveryPath) -> String {
    switch path {
    case .appPost:
        return "Drag delivered via app_post: mouse events were posted directly to the target process and the system pointer did not move. This path cannot drive window-server drag sessions such as window moves, text selection, or Finder drag-and-drop. If the drag had no effect, set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 in the server process environment to use the global pointer path, which may move the real pointer and change foreground focus."
    case .global:
        return "Drag delivered via global pointer path: OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS is enabled, so the real pointer may have moved and foreground focus may have changed."
    }
}

/// Inserts the delivery note after the snapshot text and before any screenshot,
/// so `primaryText` remains the snapshot for existing consumers.
func appendingDragDeliveryNote(to result: ToolCallResult, path: DragDeliveryPath) -> ToolCallResult {
    var content = result.content
    let insertIndex = content.firstIndex { $0.dictionary["type"] as? String == "image" } ?? content.endIndex
    content.insert(.text(dragDeliveryNote(for: path)), at: insertIndex)
    return ToolCallResult(content: content, isError: result.isError)
}

func screenshotPixelScale(
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGSize {
    guard
        let screenshotPixelSize,
        let windowBounds,
        windowBounds.width > 0,
        windowBounds.height > 0,
        screenshotPixelSize.width > 0,
        screenshotPixelSize.height > 0
    else {
        return CGSize(width: 1, height: 1)
    }

    return CGSize(
        width: screenshotPixelSize.width / windowBounds.width,
        height: screenshotPixelSize.height / windowBounds.height
    )
}

func screenshotPixelToWindowPoint(
    _ point: CGPoint,
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGPoint {
    let scale = screenshotPixelScale(
        screenshotPixelSize: screenshotPixelSize,
        windowBounds: windowBounds
    )
    return CGPoint(
        x: point.x / scale.width,
        y: point.y / scale.height
    )
}

let nonSettableSetValueErrorMessage = "Cannot set a value for an element that is not settable"

func setValueAttributeIsSettable(result: AXError, settable: Bool, attribute: String) throws -> Bool {
    guard result == .success else {
        throw ComputerUseError.message("AXUIElementIsAttributeSettable(\(attribute)) failed with \(result.rawValue)")
    }

    return settable
}

func invalidSecondaryActionErrorMessage(action: String, elementIndex: Int) -> String {
    "\(action) is not a valid secondary action for \(elementIndex)"
}

func localClickActionPoints(frame: CGRect, isSyntheticText: Bool) -> [CGPoint] {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let leading = CGPoint(
        x: frame.minX + min(max(frame.width * 0.3, 20), max(frame.width - 4, 20)),
        y: frame.midY
    )

    if isSyntheticText {
        return [leading]
    }

    if abs(leading.x - center.x) < 1 {
        return [center]
    }

    return [center, leading]
}

func isLikelySyntheticSideActionCandidate(
    parentFrame: CGRect?,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool,
    labels: [String]
) -> Bool {
    let hasSideActionLabel = labels.contains { label in
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        if normalized == "完成" || normalized == "done" || normalized == "complete" || normalized == "archive" {
            return true
        }

        if normalized.count <= 24 {
            if normalized.contains("完成") {
                return true
            }

            if normalized.contains("mark") && (normalized.contains("done") || normalized.contains("complete")) {
                return true
            }
        }

        return false
    }

    guard let parentFrame, let candidateFrame else {
        return false
    }

    let trailingBandWidth = min(max(parentFrame.width * 0.22, 56), 140)
    let isTrailing = candidateFrame.midX >= parentFrame.maxX - trailingBandWidth
    let compactWidth = candidateFrame.width <= max(88, parentFrame.width * 0.18)
    let compactHeight = candidateFrame.height <= max(44, parentFrame.height * 1.2)
    let isCompact = compactWidth && compactHeight

    if hasSideActionLabel && hasPrimaryAction && isCompact {
        return true
    }

    return isTrailing && isCompact && (hasPrimaryAction || hasSideActionLabel)
}

func shouldScanDescendantsOfHitRecord(originalFrame: CGRect?, hitFrame: CGRect?) -> Bool {
    guard let originalFrame, let hitFrame else {
        return true
    }

    let originalArea = max(originalFrame.width * originalFrame.height, 1)
    let hitArea = hitFrame.width * hitFrame.height
    if hitArea > max(originalArea * 12, 20_000) {
        return false
    }

    if hitFrame.height > max(originalFrame.height * 4, 96),
       hitFrame.width > max(originalFrame.width * 2, 240)
    {
        return false
    }

    return true
}

func isLikelyContainingRowActionFrame(
    targetFrame: CGRect,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool
) -> Bool {
    let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    guard
        hasPrimaryAction,
        let candidateFrame,
        candidateFrame.insetBy(dx: -2, dy: -2).contains(targetCenter),
        candidateFrame.width >= targetFrame.width,
        candidateFrame.height >= targetFrame.height,
        candidateFrame.height <= max(targetFrame.height + 32, targetFrame.height * 2)
    else {
        return false
    }

    return true
}

func canUseActivationOnlyClickFallback(role: String?) -> Bool {
    guard let role else {
        return false
    }

    return role == kAXWindowRole as String
}

func canUseKeyboardTextFallback(role: String?, roleDescription: String?, isValueSettable: Bool) -> Bool {
    if isValueSettable {
        return true
    }

    guard let role else {
        return false
    }

    if role == kAXTextFieldRole as String || role == "AXTextArea" || role == "AXTextView" {
        return true
    }

    guard let roleDescription = roleDescription?.lowercased() else {
        return false
    }

    return roleDescription.contains("text field")
        || roleDescription.contains("text area")
        || roleDescription.contains("text entry")
}

func isElectronScopedWebRowClickOptimizationTarget(appName: String, bundleIdentifier: String?) -> Bool {
    let normalizedBundleIdentifier = bundleIdentifier?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let normalizedName = appName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if let normalizedBundleIdentifier,
       normalizedBundleIdentifier.hasPrefix("com.electron.")
            || normalizedBundleIdentifier.contains(".electron.")
            || normalizedBundleIdentifier.contains("lark")
            || normalizedBundleIdentifier.contains("feishu")
    {
        return true
    }

    return normalizedName == "lark" || normalizedName == "feishu" || normalizedName == "飞书"
}

func shouldPreferContainingWebRowAXClickCandidate(
    role: String?,
    isSyntheticText: Bool,
    hasWebAreaAncestor: Bool,
    appName: String,
    bundleIdentifier: String?
) -> Bool {
    guard hasWebAreaAncestor,
          isElectronScopedWebRowClickOptimizationTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier
          )
    else {
        return false
    }

    guard let role else {
        return isSyntheticText
    }

    return role == kAXStaticTextRole as String || role == kAXGroupRole as String || isSyntheticText
}

public final class ComputerUseService {
    public private(set) var allowsForegroundClickOnce = false
    private var foregroundObservation: ForegroundClickObservation?
    private var snapshotCache = AppSnapshotCache()
    private var hoverPopupCache = HoverPopupCache()
    private let snapshotDependencies: SnapshotDependencies
    // Read per call: the app agent applies the caller's OPEN_COMPUTER_USE_* variables
    // for the duration of each request.
    private var actionReadBack: Bool { actionReadBackEnabled(environment: ProcessInfo.processInfo.environment) }

    private let coordinateClickBackend: CoordinateClickBackend?
    private var keyboardInputBackend: KeyboardInputBackend = .live

    public init(allowsForegroundClickOnce: Bool = false) {
        self.allowsForegroundClickOnce = allowsForegroundClickOnce
        coordinateClickBackend = nil
        snapshotDependencies = .live
    }

    init(snapshots: [String: AppSnapshot], coordinateClickBackend: CoordinateClickBackend) {
        snapshotCache = AppSnapshotCache(snapshots: snapshots)
        self.coordinateClickBackend = coordinateClickBackend
        snapshotDependencies = .live
    }

    init(snapshots: [String: AppSnapshot] = [:], snapshotDependencies: SnapshotDependencies, allowsForegroundClickOnce: Bool = false) {
        self.allowsForegroundClickOnce = allowsForegroundClickOnce
        snapshotCache = AppSnapshotCache(snapshots: snapshots, bindingIdentity: snapshotDependencies.bindingIdentity)
        coordinateClickBackend = nil
        self.snapshotDependencies = snapshotDependencies
    }

    init(snapshots: [String: AppSnapshot], keyboardInputBackend: KeyboardInputBackend) {
        snapshotCache = AppSnapshotCache(snapshots: snapshots)
        coordinateClickBackend = nil
        snapshotDependencies = .live
        self.keyboardInputBackend = keyboardInputBackend
    }

    /// An action's result reads the window back, so the app gets a beat to redraw
    /// first. Without read-back nothing is read, so there is no wait.
    private func pauseBeforeReadBack(_ interval: TimeInterval) {
        guard actionReadBack else {
            return
        }

        Thread.sleep(forTimeInterval: interval)
    }

    /// The result an action returns: the after-action snapshot, or a short status
    /// when read-back is off.
    private func actionResult(for query: String) throws -> ToolCallResult {
        guard actionReadBack else {
            return .text("ok")
        }

        return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
    }

    public func hover(app query: String, arguments: [String: Any]) throws -> ToolCallResult {
        let policy = try ExecutionPolicy.current()
        let request = try HoverRequest(arguments: arguments)
        // 只读弹层观察不依赖前台输入授权；真实 hover 必须在读取快照前拒绝。
        switch request.target {
        case .observation:
            return try readOnlyPopupObservationResult(for: query)
        case .element, .coordinates:
            try policy.requireForeground("Hover")
            guard foregroundHoverEnabled(environment: ProcessInfo.processInfo.environment) else {
                throw ComputerUseError.unsupportedTool("hover")
            }
        }
        let snapshot = try currentSnapshot(for: query)
        do {
            let target = try hoverTarget(request, snapshot: snapshot)
            let point = target.point
            return try dispatchForegroundHover(
                validateTarget: {
                    try target.validate()
                    try InputSimulation.requireReleasedMouseButtons()
                    try self.validateCoordinateSnapshot(at: point, snapshot: snapshot, identityOnly: true)
                },
                prepare: {
                    guard let window = snapshot.windowElement else {
                        throw ComputerUseError.stateUnavailable("Snapshot window is unavailable; observe again")
                    }
                    try InputSimulation.prepareWindowForForegroundClick(snapshot.app, window: window)
                },
                validateReceiver: {
                    guard let window = snapshot.windowElement,
                          InputSimulation.isForegroundWindow(snapshot.app, window: window) else {
                        throw ComputerUseError.stateUnavailable("Foreground window changed; observe again")
                    }
                    try target.validate()
                    try self.validateCoordinateSnapshot(at: point, snapshot: snapshot, requireUnoccludedPoint: true)
                },
                submit: {
                    try InputDiagnostics.input(route: .global, point: point) {
                        try InputSimulation.movePointerForHover(at: inputEventPoint(fromScreenStatePoint: point))
                    }
                },
                dwell: { Thread.sleep(forTimeInterval: Double(request.durationMilliseconds) / 1000) },
                readBack: {
                    // hover 总是回读，不能受普通动作的 read-back 开关影响。
                    try self.popupObservationResult(for: query)
                }
            )
        } catch {
            snapshotCache.invalidate(query: query, resolvedApp: snapshot.app)
            LiveWindowPreview.invalidate()
            throw error
        }
    }

    private func readOnlyPopupObservationResult(for query: String) throws -> ToolCallResult {
        hoverPopupCache.clear()
        foregroundObservation = nil
        do {
            let app: RunningAppDescriptor
            var recoveryBinding: SnapshotObservationBinding?
            do {
                // 正常观察沿用已绑定身份，避免同名应用让目标悄然改变。
                app = try snapshotCache.snapshot(for: query).app
            } catch ComputerUseError.stateUnavailable {
                recoveryBinding = snapshotCache.observationBinding(for: query)
                if let recoveryBinding {
                    app = recoveryBinding.app
                } else {
                    // 仅从未绑定的查询允许解析；失败恢复不能借同名或重启切换进程。
                    app = try snapshotDependencies.resolve(query)
                }
            }
            snapshotCache.invalidate(query: query, resolvedApp: recoveryBinding == nil ? app : nil)
            let fresh = try observeWithoutActivation {
                // 恢复的每次尝试前后复核 PID 与启动时间；退出或 PID 复用均拒绝。
                try recoveryBinding?.validate(current: snapshotDependencies.processIdentity(app.pid))
                let snapshot = try snapshotDependencies.build(app, .defaults, .defaults, .readOnly)
                try recoveryBinding?.validate(current: snapshotDependencies.processIdentity(app.pid))
                return snapshot
            }
            // 新索引仅在完整主快照成功后生效；不恢复旧 token 或单次前台资格。
            snapshotCache.recordObservation(fresh, for: query)
            return snapshotResult(for: fresh, style: .fullState, reportMissingPopups: true)
        } catch {
            snapshotCache.invalidate(query: query)
            LiveWindowPreview.invalidate()
            throw error
        }
    }

    private func popupObservationResult(for query: String) throws -> ToolCallResult {
        let fresh = try refreshSnapshot(for: query)
        return snapshotResult(for: fresh, style: .actionResult, reportMissingPopups: true)
    }

    func discardHoverPopups() { hoverPopupCache.clear() }

    func clickPopup(app query: String, arguments: [String: Any]) throws -> ToolCallResult {
        // 参数失败和授权开关变化也必须消耗旧观察。
        var pending = hoverPopupCache
        hoverPopupCache.clear()
        let request = try HoverPopupClickRequest(arguments: arguments)
        let lease = try pending.take(request.token)
        if request.method == .global {
            try ExecutionPolicy.current().requireForeground("Popup global click")
            guard foregroundHoverEnabled(environment: ProcessInfo.processInfo.environment) else {
                throw ComputerUseError.unsupportedTool("hover popup click")
            }
        }
        try validateClickMethod(
            request.method, hasElementIndex: false, environment: ProcessInfo.processInfo.environment
        )
        let snapshot = try currentSnapshot(for: query)
        var point = CGPoint.zero
        do {
            return try dispatchPopupClick(
                method: request.method,
                validate: { point = try validateHoverPopupClick(lease, request: request, snapshot: snapshot) },
                submit: { try submitHoverPopupClick(lease, request: request, snapshot: snapshot, point: point) },
                readBack: { try self.snapshotResult(for: self.refreshSnapshot(for: query), style: .actionResult) }
            )
        } catch {
            snapshotCache.invalidate(query: query, resolvedApp: snapshot.app)
            LiveWindowPreview.invalidate()
            throw error
        }
    }

    private func hoverTarget(
        _ request: HoverRequest, snapshot: AppSnapshot
    ) throws -> (point: CGPoint, validate: () throws -> Void) {
        switch request.target {
        case .observation:
            throw ComputerUseError.invalidArguments("Read-only popup observation has no input target")
        case let .element(index):
            let record = try lookupElement(snapshot: snapshot, index: index)
            guard let center = try globalPoint(for: record, snapshot: snapshot),
                  let element = record.element else {
                throw ComputerUseError.stateUnavailable("Hover element has no actionable frame; observe again")
            }
            // 编号来自已交付快照；激活前后均拒绝已迁移或消失的控件。
            return (center, {
                guard self.elementBelongsToSnapshotWindow(element, snapshot: snapshot) == true,
                      self.localFrame(of: element, windowBounds: snapshot.windowBounds) == record.localFrame else {
                    throw ComputerUseError.stateUnavailable("Hover element changed; observe again")
                }
            })
        case let .coordinates(x, y):
            guard snapshot.screenshotData != nil else {
                throw ComputerUseError.stateUnavailable("Coordinate hover requires a delivered screenshot")
            }
            return (try screenshotToGlobalPoint(snapshot: snapshot, x: x, y: y), {})
        }
    }

    public func listApps() -> ToolCallResult {
        ToolCallResult.text(
            AppDiscovery.listCatalog()
                .map(\.renderedLine)
                .joined(separator: "\n")
        )
    }

    private func initializeAppSnapshot(
        for query: String,
        textLimit: SnapshotTextLimit,
        treeLimits: AccessibilityTreeLimits
    ) throws -> AppSnapshot {
        hoverPopupCache.clear()
        let observationError: ComputerUseError
        do {
            // 已有可观察窗口直接绑定；只有无进程或明确无窗口才请求系统打开。
            return try observeWithoutActivation {
                try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, explicitObservation: true)
            }
        } catch let error as ComputerUseError {
            switch error {
            case .appNotFound:
                // 冷启动由下方唯一的打开请求完成。
                break
            case .stateUnavailable(let message) where message == computerUseNoWindowFoundMessage:
                // 运行中但没有窗口时，reopen 可恢复应用自己的打开/新建入口。
                break
            default:
                throw error
            }
            observationError = error
        }

        // 定位与执行分离：先固定目标，未知打开结果不能被名称、bundle ID 或路径别名绕过。
        let request = try snapshotDependencies.prepareOpen(query)
        guard !snapshotCache.hasPendingInitialization(for: request.identity) else { throw observationError }
        // 打开可能改变窗口拓扑；成功回读前不能继续使用旧输入快照。
        snapshotCache.beginInitialization(for: request.identity, query: query)
        LiveWindowPreview.invalidate()
        let app = try request.perform()
        snapshotCache.invalidate(query: query, resolvedApp: app)
        // 使用系统回调身份，只重试观察，不重复发送 launch/reopen。
        let snapshot = try observeWithoutActivation {
            try snapshotDependencies.build(app, textLimit, treeLimits, .readOnly)
        }
        snapshotCache.finishInitialization(for: request.identity)
        return snapshot
    }

    public func getAppState(
        app query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        windowPlacement: WindowPlacement = .keep,
        initialize: Bool = false
    ) throws -> ToolCallResult {
        _ = try ExecutionPolicy.current()
        guard !initialize || windowPlacement == .keep else {
            throw ComputerUseError.invalidArguments("initialize cannot be combined with window_placement")
        }
        foregroundObservation = nil
        var observationSucceeded = false
        defer {
            // 放置窗口或最终回读失败时，中间生成的快照也不能继续用于输入。
            if !observationSucceeded {
                snapshotCache.invalidate(query: query)
                LiveWindowPreview.invalidate()
            }
        }
        if initialize {
            let snapshot = try initializeAppSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits)
            snapshotCache.recordObservation(snapshot, for: query)
            foregroundObservation = ForegroundClickObservation(app: query, observedAt: ProcessInfo.processInfo.systemUptime)
            observationSucceeded = true
            return snapshotResult(for: snapshot, style: .fullState)
        }
        guard windowPlacement != .keep else {
            let snapshot = try observeWithoutActivation {
                try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, explicitObservation: true)
            }
            snapshotCache.recordObservation(snapshot, for: query)
            foregroundObservation = ForegroundClickObservation(app: query, observedAt: ProcessInfo.processInfo.systemUptime)
            observationSucceeded = true
            return snapshotResult(for: snapshot, style: .fullState)
        }

        // Explicit placements never activate or raise; they only move the frame.
        let snapshot = try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, explicitObservation: true)
        guard snapshot.mode != .fixture else {
            throw ComputerUseError.message("window_placement '\(windowPlacement.rawValue)' is not supported for fixture apps")
        }
        switch windowPlacement {
        case .agentDisplay:
            guard let windowID = snapshot.targetWindowID, let windowElement = snapshot.windowElement else {
                throw ComputerUseError.stateUnavailable("window_placement 'agent_display' requires a current target window. Run get_app_state again.")
            }
            try snapshotDependencies.parkWindow(windowID, snapshot.app.pid, windowElement)
        case .restore:
            try snapshotDependencies.restoreWindows(snapshot.app.pid)
        case .keep:
            break
        }

        let finalSnapshot = try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, explicitObservation: true)
        snapshotCache.recordObservation(finalSnapshot, for: query)
        foregroundObservation = ForegroundClickObservation(app: query, observedAt: ProcessInfo.processInfo.systemUptime)
        observationSucceeded = true
        return snapshotResult(for: finalSnapshot, style: .fullState)
    }

    // 在参数校验前消费；错误参数、其他操作或重复请求也不能保留资格。
    func takeForegroundObservation() -> ForegroundClickObservation? {
        defer { foregroundObservation = nil }
        return foregroundObservation
    }

    func clickForegroundOnce(app query: String, x: Double, y: Double, observation: ForegroundClickObservation?) throws -> ToolCallResult {
        guard allowsForegroundClickOnce else {
            throw ComputerUseError.stateUnavailable("Host has not enabled single foreground clicks; no input was sent.")
        }
        guard let observation else {
            throw ComputerUseError.stateUnavailable("Run get_app_state immediately before click_foreground_once; no input was sent.")
        }
        try observation.validate(app: query, now: ProcessInfo.processInfo.systemUptime)
        let snapshot = try currentSnapshot(for: query)
        // 从此不论激活、投递还是回读失败，都必须重新观察，不能沿旧快照重放。
        snapshotCache.invalidate(query: query, resolvedApp: snapshot.app)
        guard snapshot.screenshotData != nil, x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw ComputerUseError.invalidArguments("A screenshot and finite non-negative coordinates are required; no input was sent.")
        }
        let point = try screenshotToGlobalPoint(snapshot: snapshot, x: x, y: y)
        try performForegroundClick(at: point, button: .left, clickCount: 1, snapshot: snapshot, authorization: .hostSingleClick)
        return .text("Single foreground click submitted; UI effect is unverified. The one-call capability ended. Run get_app_state before further input; normal input remains background-routed.")
    }

    public func click(
        app query: String,
        elementIndex: String?,
        x: Double?,
        y: Double?,
        clickCount: Int,
        mouseButton: String,
        clickMethod: ClickMethod = .auto
    ) throws -> ToolCallResult {
        try validateClickMethod(
            clickMethod,
            hasElementIndex: elementIndex != nil,
            environment: ProcessInfo.processInfo.environment
        )
        try validateSkyClickArguments(
            method: clickMethod,
            mouseButton: mouseButton,
            clickCount: clickCount
        )

        guard let button = MouseButtonKind(rawValue: mouseButton.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()), clickCount > 0
        else {
            throw ComputerUseError
                .invalidArguments("click requires mouse_button left/right/middle and a positive click_count")
        }
        let snapshot = try currentSnapshot(for: query)
        InputDiagnostics.event("click_target", [
            "requested_method": clickMethod.rawValue, "target_pid": String(snapshot.app.pid),
            "window_id": snapshot.targetWindowID.map(String.init) ?? "unknown",
            "window_bounds": InputDiagnostics.bounds(snapshot.windowBounds),
            "target_kind": elementIndex == nil ? "coordinate" : "element", "button": button.rawValue,
            "click_count": String(clickCount),
            "foreground_pid": NSWorkspace.shared.frontmostApplication.map { String($0.processIdentifier) } ?? "unknown",
        ])
        if snapshot.mode == .fixture {
            guard clickMethod == .auto else {
                throw ComputerUseError.message(
                    "click_method '\(clickMethod.rawValue)' is not supported for fixture apps"
                )
            }

            let cursorTarget: VisualCursorTarget?
            if let elementIndex {
                let record = try lookupElement(snapshot: snapshot, index: elementIndex)
                guard let identifier = record.identifier else {
                    throw ComputerUseError.invalidArguments("fixture click requires an identifier-backed element")
                }
                cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier))
            } else if let x, let y {
                let identifier = try fixtureIdentifier(at: CGPoint(x: x, y: y), snapshot: snapshot)
                cursorTarget = fixtureVisualCursorTarget(identifier: identifier, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier, x: x, y: y))
            } else {
                throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
            }

            Thread.sleep(forTimeInterval: 0.15)
            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
            return try actionResult(for: query)
        }

        if let elementIndex {
            let record = try lookupElement(snapshot: snapshot, index: elementIndex)
            guard let windowPoint = clickPoint(for: record, snapshot: snapshot) else {
                throw ComputerUseError.stateUnavailable("element \(elementIndex) has no clickable frame")
            }
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: windowPoint)
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto:
                    if !(try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: true,
                        allowActivationFallback: false
                    )) {
                        try performNonAXClickFallback(
                            at: targetPoint,
                            button: button,
                            clickCount: clickCount,
                            targetDescription: "element_index=\(elementIndex)",
                            snapshot: snapshot
                        )
                    }
                case .accessibility:
                    guard try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: true,
                        allowActivationFallback: try !ExecutionPolicy.current().isBackground
                    ) else {
                        throw ComputerUseError.message(
                            "click_method 'accessibility' could not click element_index=\(elementIndex)"
                        )
                    }
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        at: targetPoint,
                        windowPoint: windowPoint,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: "element_index=\(elementIndex)",
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
        } else if let x, let y {
            let screenshotPoint = CGPoint(x: x, y: y)
            let point = try screenshotPixelToWindowPointInSnapshot(snapshot: snapshot, point: screenshotPoint)
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: point)
            let pixelSize = screenshotPixelSize(snapshot: snapshot)
            InputDiagnostics.event("coordinate_mapping", [
                "screenshot_point": InputDiagnostics.point(screenshotPoint),
                "screenshot_size": pixelSize.map { "\($0.width),\($0.height)" } ?? "unknown",
                "window_point": InputDiagnostics.point(point), "screen_point": InputDiagnostics.point(targetPoint),
            ])
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto:
                    try performCoordinateClick(
                        at: point,
                        globalPoint: targetPoint,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount
                    )
                case .accessibility:
                    throw ComputerUseError.message("click_method 'accessibility' requires element_index")
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        at: targetPoint,
                        windowPoint: point,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: "x=\(Int(screenshotPoint.x)) y=\(Int(screenshotPoint.y))",
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
        } else {
            throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
        }

        return try actionResult(for: query)
    }

    public func performSecondaryAction(app query: String, elementIndex: String, action: String) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard action.caseInsensitiveCompare("Raise") == .orderedSame else {
                throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
            }

            return try actionResult(for: query)
        }

        guard let rawAction = matchingAction(requested: action, record: record) else {
            throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }

        try ExecutionPolicy.current().requireAXAction(rawAction)
        let result = AXUIElementPerformAction(element, rawAction as CFString)
        guard result == .success else {
            throw ComputerUseError.message("AXUIElementPerformAction failed with \(result.rawValue)")
        }

        pauseBeforeReadBack(0.15)
        return try actionResult(for: query)
    }

    public func scroll(app query: String, direction: String, elementIndex: String, pages: Double) throws -> ToolCallResult {
        let normalized = direction.lowercased()
        guard ["up", "down", "left", "right"].contains(normalized) else {
            throw ComputerUseError.message("Invalid scroll direction: \(direction)")
        }
        guard pages.isFinite, pages > 0 else {
            throw ComputerUseError.message("pages must be > 0")
        }

        let snapshot = try currentSnapshot(for: query)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture scroll requires an identifier-backed element")
            }
            try FixtureBridge.post(FixtureCommand(kind: "scroll", identifier: identifier, direction: normalized, pages: pages))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        if let repeatCount = integralScrollPageCount(pages),
           let rawAction = record.rawActions.first(where: { $0.caseInsensitiveCompare("AXScroll\(normalized.capitalized)ByPage") == .orderedSame }),
           let element = record.element {
            for _ in 0..<repeatCount {
                _ = AXUIElementPerformAction(element, rawAction as CFString)
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else if let point = try globalPoint(for: record, snapshot: snapshot) {
            try performScrollEvent(
                at: point,
                direction: normalized,
                pages: pages,
                targetDescription: "element_index=\(elementIndex)",
                snapshot: snapshot
            )
        } else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no scrollable frame")
        }

        return try actionResult(for: query)
    }

    public func drag(app query: String, fromX: Double, fromY: Double, toX: Double, toY: Double) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        if snapshot.mode == .fixture {
            try FixtureBridge.post(FixtureCommand(kind: "drag", identifier: "fixture-drag-pad", x: fromX, y: fromY, toX: toX, toY: toY))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        let start = try screenshotToGlobalPoint(snapshot: snapshot, x: fromX, y: fromY)
        let end = try screenshotToGlobalPoint(snapshot: snapshot, x: toX, y: toY)
        let path = try performDragEvent(
            from: start,
            to: end,
            targetDescription: "from=(\(Int(fromX)), \(Int(fromY))) to=(\(Int(toX)), \(Int(toY)))",
            snapshot: snapshot
        )
        return appendingDragDeliveryNote(
            to: try actionResult(for: query),
            path: path
        )
    }

    public func typeText(app query: String, text: String, keyMethod: KeyMethod = .auto) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        if snapshot.mode == .fixture {
            try requireAutoKeyMethodForFixture(keyMethod)
            try FixtureBridge.post(FixtureCommand(kind: "type_text", identifier: "fixture-input", value: text))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        let target = try skyKeyTarget(for: snapshot)
        // 显式 sky_key 与上游一致：视觉确认的输入目标不必暴露 AX 文本焦点。
        if keyMethod == .skyKey {
            try keyboardInputBackend.validateWindow(snapshot)
            try keyboardInputBackend.typeText(target, text, {
                try keyboardInputBackend.validateWindow(snapshot)
            })
            return try actionResult(for: query)
        }
        let receiver = try keyboardInputBackend.readReceiver(snapshot, true)
        // 点击可在不刷新快照的情况下改变焦点；输入前与合成 key 状态建立后均实时校验。
        try keyboardInputBackend.typeText(target, text, {
            try requireSameKeyboardReceiver(receiver, current: keyboardInputBackend.readReceiver(snapshot, true))
        })
        return try actionResult(for: query)
    }

    public func pressKey(app query: String, key: String, keyMethod: KeyMethod = .auto) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        if snapshot.mode == .fixture {
            try requireAutoKeyMethodForFixture(keyMethod)
            try FixtureBridge.post(FixtureCommand(kind: "press_key", identifier: "fixture-key-capture", value: key))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        let target = try skyKeyTarget(for: snapshot)
        try keyboardInputBackend.pressKey(target, key, {
            if keyMethod == .skyKey {
                try keyboardInputBackend.validateWindow(snapshot)
            } else {
                _ = try keyboardInputBackend.readReceiver(snapshot, false)
            }
        })
        return try actionResult(for: query)
    }

    public func pasteText(app query: String, text: String) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        guard snapshot.mode != .fixture else {
            throw ComputerUseError.message("paste_text is unavailable for fixture apps")
        }
        let target = try skyKeyTarget(for: snapshot)
        try keyboardInputBackend.validateWindow(snapshot)
        try keyboardInputBackend.pasteText(target, text, {
            try keyboardInputBackend.validateWindow(snapshot)
        })
        return try actionResult(for: query)
    }

    private func requireAutoKeyMethodForFixture(_ keyMethod: KeyMethod) throws {
        guard keyMethod == .auto else {
            throw ComputerUseError.message(
                "key_method '\(keyMethod.rawValue)' is not supported for fixture apps"
            )
        }
    }

    private func skyKeyTarget(for snapshot: AppSnapshot) throws -> SkyKeyboardTarget {
        guard let windowID = snapshot.targetWindowID else {
            throw ComputerUseError.stateUnavailable(
                "key_method 'sky_key' requires a current on-screen target window. Run get_app_state again."
            )
        }

        return SkyKeyboardTarget(windowID: windowID, pid: snapshot.app.pid)
    }

    public func setValue(app query: String, elementIndex: String, value: String) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture set_value requires a known element identifier")
            }

            let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
            moveVisualCursor(to: cursorTarget)
            try FixtureBridge.post(FixtureCommand(kind: "set_value", identifier: identifier, value: value))
            Thread.sleep(forTimeInterval: 0.15)
            settleVisualCursor(at: cursorTarget)
            return try actionResult(for: query)
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }

        guard try isSettableForSetValue(element: element, attribute: kAXValueAttribute) else {
            throw ComputerUseError.message(nonSettableSetValueErrorMessage)
        }

        let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
        moveVisualCursor(to: cursorTarget)

        do {
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            guard result == .success else {
                throw ComputerUseError.message("AXUIElementSetAttributeValue failed with \(result.rawValue)")
            }

            pauseBeforeReadBack(0.1)
        } catch {
            settleVisualCursor(at: cursorTarget)
            throw error
        }

        settleVisualCursor(at: cursorTarget)
        return try actionResult(for: query)
    }

    private func currentSnapshot(for query: String) throws -> AppSnapshot {
        _ = try ExecutionPolicy.current()
        hoverPopupCache.clear()
        let snapshot = try snapshotCache.snapshot(for: query)
        LiveWindowPreview.publish(snapshot)
        return snapshot
    }

    @discardableResult
    private func refreshSnapshot(
        for query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        explicitObservation: Bool = false
    ) throws -> AppSnapshot {
        hoverPopupCache.clear()
        var resolvedApp: RunningAppDescriptor?
        do {
            let app: RunningAppDescriptor
            if explicitObservation {
                app = try snapshotDependencies.resolve(query)
                // 显式观察完成前暂停该目标输入；放置阶段的中间快照不发布到缓存。
                snapshotCache.invalidate(query: query, resolvedApp: app)
            } else {
                app = try currentSnapshot(for: query).app
            }
            resolvedApp = app
            // 所有 service 回读都只观察，不能沿旧动作策略恢复焦点或重开窗口。
            let snapshot = try snapshotDependencies.build(app, textLimit, treeLimits, .readOnly)
            if !explicitObservation {
                try snapshotCache.recordReadBack(snapshot, for: query)
            }
            return snapshot
        } catch {
            snapshotCache.invalidate(query: query, resolvedApp: resolvedApp)
            throw error
        }
    }

    private func lookupElement(snapshot: AppSnapshot, index: String) throws -> ElementRecord {
        guard let parsedIndex = Int(index), let record = snapshot.elements[parsedIndex] else {
            throw ComputerUseError.invalidArguments("unknown element_index '\(index)'")
        }

        return record
    }

    func matchingAction(requested: String, record: ElementRecord) -> String? {
        if let exact = record.rawActions.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }
        let visibleActions = record.role.map { meaningfulRawActions(record.rawActions, role: $0) } ?? record.rawActions
        let matches = visibleActions.filter { rawAction in
            secondaryActionNamesEquivalent(requested, secondaryActionDisplayName(rawAction))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func invalidSecondaryActionMessage(action: String, record: ElementRecord) -> String {
        invalidSecondaryActionErrorMessage(action: action, elementIndex: record.index)
    }

    private func performPreferredClick(on record: ElementRecord, button: MouseButtonKind, clickCount: Int) throws -> Bool {
        guard let element = record.element else {
            return false
        }

        switch button {
        case .left:
            if clickCount <= 1,
               !hasAncestorRole("AXWebArea", of: element),
               try selectContainingListItem(for: element)
            {
                return true
            }

            if try performAction(named: kAXPressAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if try performAction(named: kAXConfirmAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if try performAction(named: "AXOpen", on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .right:
            if try performAction(named: kAXShowMenuAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .middle:
            break
        }

        return false
    }

    private func performCoordinateClick(
        at windowPoint: CGPoint,
        globalPoint: CGPoint,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int
    ) throws {
        let backend = coordinateClickBackend ?? liveCoordinateClickBackend()
        try backend.validateWindow(globalPoint, snapshot)
        let hit = try backend.hitTest(globalPoint, snapshot)
        InputDiagnostics.event("coordinate_hit", [
            "found": String(hit != nil), "window_match": hit?.target.belongsToWindow.map(String.init) ?? "unknown",
            "frame": InputDiagnostics.bounds(hit?.target.frame),
            "supports_press": String(hit?.target.actions.contains(kAXPressAction) == true),
            "supports_menu": String(hit?.target.actions.contains(kAXShowMenuAction) == true),
        ])
        try dispatchCoordinateClick(
            at: windowPoint,
            target: hit?.target,
            button: button,
            clickCount: clickCount,
            validateWindow: { try backend.validateWindow(globalPoint, snapshot) },
            performAX: { action in
                guard let hit else {
                    throw ComputerUseError.stateUnavailable("Coordinate hit target is unavailable; observe again")
                }
                return try hit.performAX(action)
            },
            performMouse: { try backend.performMouse(globalPoint, button, clickCount, snapshot) }
        )
    }

    private func liveCoordinateClickBackend() -> CoordinateClickBackend {
        // 闭包仅在本次同步调用存活，不存回 service，避免形成持有环。
        CoordinateClickBackend(
            validateWindow: { point, snapshot in
                try self.validateCoordinateSnapshot(at: point, snapshot: snapshot)
            },
            hitTest: { globalPoint, snapshot in
                guard let record = try self.hitTestElement(atGlobalPoint: globalPoint, in: snapshot, strictQueryErrors: true),
                      let element = record.element else { return nil }
                return CoordinateClickHit(
                    target: CoordinateClickTarget(
                        role: record.role,
                        frame: record.localFrame,
                        actions: record.rawActions,
                        belongsToWindow: self.elementBelongsToSnapshotWindow(element, snapshot: snapshot)
                    ),
                    performAX: { action in
                        self.debugClickDecision("requested=auto executed=coordinate_ax action=\(action)")
                        InputDiagnostics.event("input_attempt", ["route": "coordinate_ax", "action": action == kAXPressAction ? "press" : "show_menu"])
                        let result = AXUIElementPerformAction(element, action as CFString)
                        InputDiagnostics.event("input_returned", ["route": "coordinate_ax", "ax_result": String(result.rawValue)])
                        return result
                    }
                )
            },
            performMouse: { point, button, clickCount, snapshot in
                try self.performNonAXClickFallback(
                    at: point, button: button, clickCount: clickCount,
                    targetDescription: "auto coordinate", snapshot: snapshot
                )
            }
        )
    }

    private func validateCoordinateSnapshot(
        at point: CGPoint, snapshot: AppSnapshot, requireUnoccludedPoint: Bool = false, identityOnly: Bool = false
    ) throws {
        guard !snapshot.app.runningApplication.isTerminated, !snapshot.app.runningApplication.isHidden,
              let windowID = snapshot.targetWindowID, let bounds = snapshot.windowBounds,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            throw ComputerUseError.stateUnavailable("Coordinate target window is unavailable; run get_app_state again")
        }
        try validateCoordinateWindow(
            windowID: windowID, pid: snapshot.app.pid, bounds: bounds, point: point,
            windows: windows, requireUnoccludedPoint: requireUnoccludedPoint, identityOnly: identityOnly,
            spacesForWindow: { SkyLightSPI.shared.spaces(forWindow: $0) },
            mouseReceiver: foregroundMouseReceiver,
            backgroundWindows: { isOnScreen in
                try coordinateWindowObstructions(
                    windowID: windowID, pid: snapshot.app.pid, bounds: bounds, point: point, isOnScreen: isOnScreen
                )
            }
        )
    }

    private func elementBelongsToSnapshotWindow(_ element: AXUIElement?, snapshot: AppSnapshot) -> Bool? {
        guard let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == snapshot.app.pid else { return false }
        guard let window = snapshot.windowElement else { return nil }
        if CFEqual(element, window) { return true }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return CFEqual(value, window)
    }

    private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return CFEqual(lhs, rhs)
    }

    private func selectContainingListItem(for element: AXUIElement) throws -> Bool {
        guard let target = selectableListItem(containing: element) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            target.list,
            kAXSelectedChildrenAttribute as CFString,
            [target.item] as CFArray
        )

        switch result {
        case .success:
            pauseBeforeReadBack(0.15)
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue(\(kAXSelectedChildrenAttribute)) failed with \(result.rawValue)")
        }
    }

    private func selectableListItem(containing element: AXUIElement) -> (list: AXUIElement, item: AXUIElement)? {
        var current = element
        var directChild = element

        for _ in 0..<8 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == kAXListRole as String,
               isSettable(element: parent, attribute: kAXSelectedChildrenAttribute)
            {
                return (parent, directChild)
            }

            directChild = parent
            current = parent
        }

        return nil
    }

    private func performAXClickSequence(
        on record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int,
        includeNearbyHitTesting: Bool,
        allowActivationFallback: Bool
    ) throws -> Bool {
        let preferContainingWebRowAXClick = shouldPreferContainingWebRowAXClick(record, in: snapshot)
        debugClickDecision("record=\(clickDebugDescription(record)) preferContainingWebRowAXClick=\(preferContainingWebRowAXClick)")

        if preferContainingWebRowAXClick,
           try performContainingWebRowClick(for: record, snapshot: snapshot, button: button, clickCount: clickCount)
        {
            pauseBeforeReadBack(0.15)
            return true
        }

        if !preferContainingWebRowAXClick {
            if try performPreferredClick(on: record, button: button, clickCount: clickCount) {
                debugClickDecision("handled by preferred target \(clickDebugDescription(record))")
                pauseBeforeReadBack(0.15)
                return true
            }

            for candidate in descendantClickCandidates(for: record, snapshot: snapshot) {
                if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                    debugClickDecision("handled by descendant \(clickDebugDescription(candidate))")
                    pauseBeforeReadBack(0.15)
                    return true
                }
            }

            if includeNearbyHitTesting {
                for localPoint in clickActionPoints(for: record, snapshot: snapshot) {
                    guard let hitRecord = try hitTestElement(atWindowPoint: localPoint, in: snapshot) ?? bestElement(containing: localPoint, in: snapshot) else {
                        continue
                    }

                    if !isLikelySyntheticSideAction(hitRecord, in: record),
                       try performPreferredClick(on: hitRecord, button: button, clickCount: clickCount)
                    {
                        debugClickDecision("handled by hit record \(clickDebugDescription(hitRecord))")
                        pauseBeforeReadBack(0.15)
                        return true
                    }

                    if shouldScanDescendantsOfHitRecord(
                        originalFrame: clickFrame(for: record, snapshot: snapshot),
                        hitFrame: hitRecord.localFrame
                    ) {
                        for candidate in descendantClickCandidates(
                            for: hitRecord,
                            snapshot: snapshot,
                            sideActionScope: record
                        ) {
                            if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                                debugClickDecision("handled by hit descendant \(clickDebugDescription(candidate))")
                                pauseBeforeReadBack(0.15)
                                return true
                            }
                        }
                    }
                }
            }
        }

        guard
            allowActivationFallback,
            !record.isSyntheticText,
            button == .left,
            let element = record.element,
            canUseActivationOnlyClickFallback(role: stringValue(of: element, attribute: kAXRoleAttribute))
        else {
            return false
        }

        if try activateClickTarget(element: element, availableActions: record.rawActions) {
            debugClickDecision("handled by activation fallback \(clickDebugDescription(record))")
            pauseBeforeReadBack(0.15)
            return true
        }

        return false
    }

    private func performAction(named action: String, on element: AXUIElement, availableActions: [String], repeatCount: Int = 1) throws -> Bool {
        try executeAXAction(
            named: action,
            availableActions: availableActions,
            repeatCount: repeatCount,
            perform: { AXUIElementPerformAction(element, action as CFString) }
        ) == .completed
    }

    private func activateClickTarget(element: AXUIElement, availableActions: [String]) throws -> Bool {
        try ExecutionPolicy.current().requireForeground("Accessibility activation")
        var activated = false

        if try performAction(named: kAXRaiseAction as String, on: element, availableActions: availableActions) {
            activated = true
        }

        if try setBoolAttribute(named: kAXMainAttribute, on: element) {
            activated = true
        }

        if try setBoolAttribute(named: kAXFocusedAttribute, on: element) {
            activated = true
        }

        return activated
    }

    private func setBoolAttribute(named attribute: String, on element: AXUIElement) throws -> Bool {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue)
        switch result {
        case .success:
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue(\(attribute)) failed with \(result.rawValue)")
        }
    }

    private func isSettable(element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    private func isSettableForSetValue(element: AXUIElement, attribute: String) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return try setValueAttributeIsSettable(
            result: result,
            settable: settable.boolValue,
            attribute: attribute
        )
    }

    private func bestElement(containing point: CGPoint, in snapshot: AppSnapshot) -> ElementRecord? {
        snapshot.elements.values
            .filter { $0.localFrame?.contains(point) ?? false }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
            .first
    }

    private func hitTestElement(atWindowPoint point: CGPoint, in snapshot: AppSnapshot) throws -> ElementRecord? {
        try hitTestElement(atGlobalPoint: windowPointToGlobalPoint(snapshot: snapshot, point: point), in: snapshot)
    }

    private func hitTestElement(atGlobalPoint globalPoint: CGPoint, in snapshot: AppSnapshot, strictQueryErrors: Bool = false) throws -> ElementRecord? {
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appElement, Float(globalPoint.x), Float(globalPoint.y), &hitElement)
        if strictQueryErrors {
            guard try coordinateHitTestHasElement(result) else { return nil }
            guard hitElement != nil else {
                throw ComputerUseError.stateUnavailable("AX hit test returned an empty success; observe again")
            }
        }
        guard result == .success, let hitElement else { return nil }

        let rawActions = copyActions(for: hitElement) ?? []
        return ElementRecord(
            index: -1,
            identifier: nil,
            element: hitElement,
            localFrame: localFrame(of: hitElement, windowBounds: snapshot.windowBounds),
            role: stringValue(of: hitElement, attribute: kAXRoleAttribute),
            rawActions: rawActions,
            prettyActions: rawActions
        )
    }

    private func clickPriority(for record: ElementRecord) -> Int {
        if record.rawActions.contains(where: {
            $0.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame
        }) {
            return 0
        }

        if let element = record.element,
           isSettable(element: element, attribute: kAXMainAttribute) ||
           isSettable(element: element, attribute: kAXFocusedAttribute) {
            return 1
        }

        return 2
    }

    private func frameArea(of record: ElementRecord) -> CGFloat {
        guard let frame = record.localFrame else {
            return .greatestFiniteMagnitude
        }

        return frame.width * frame.height
    }

    private func localCenter(for record: ElementRecord) -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func clickActionPoints(for record: ElementRecord, snapshot: AppSnapshot) -> [CGPoint] {
        guard let frame = clickFrame(for: record, snapshot: snapshot) else {
            return []
        }

        return localClickActionPoints(frame: frame, isSyntheticText: record.isSyntheticText)
    }

    private func descendantClickCandidates(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        sideActionScope: ElementRecord? = nil
    ) -> [ElementRecord] {
        guard let element = record.element else {
            return []
        }

        let sideActionParent = sideActionScope ?? record
        return descendantClickCandidates(of: element, windowBounds: snapshot.windowBounds)
            .filter { candidate in
                !isLikelySyntheticSideAction(candidate, in: sideActionParent)
            }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
    }

    private func descendantClickCandidates(of element: AXUIElement, windowBounds: CGRect?, depth: Int = 0) -> [ElementRecord] {
        guard depth < 3 else {
            return []
        }

        var results: [ElementRecord] = []
        for child in copyChildren(of: element) {
            let rawActions = copyActions(for: child) ?? []
            results.append(
                ElementRecord(
                    index: -1,
                    identifier: nil,
                    element: child,
                    localFrame: localFrame(of: child, windowBounds: windowBounds),
                    rawActions: rawActions,
                    prettyActions: rawActions
                )
            )
            results.append(contentsOf: descendantClickCandidates(of: child, windowBounds: windowBounds, depth: depth + 1))
        }

        return results
    }

    private func isLikelySyntheticSideAction(_ candidate: ElementRecord, in parent: ElementRecord) -> Bool {
        isLikelySyntheticSideActionCandidate(
            parentFrame: parent.localFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate),
            labels: accessibilityLabels(for: candidate.element)
        )
    }

    private func hasPrimaryClickAction(_ record: ElementRecord) -> Bool {
        record.rawActions.contains { action in
            action.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
                action.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
                action.caseInsensitiveCompare("AXOpen") == .orderedSame ||
                action.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame
        }
    }

    private func shouldPreferContainingWebRowAXClick(_ record: ElementRecord, in snapshot: AppSnapshot) -> Bool {
        guard
            let element = record.element
        else {
            return false
        }

        return shouldPreferContainingWebRowAXClickCandidate(
            role: stringValue(of: element, attribute: kAXRoleAttribute),
            isSyntheticText: record.isSyntheticText,
            hasWebAreaAncestor: hasAncestorRole("AXWebArea", of: element),
            appName: snapshot.app.name,
            bundleIdentifier: snapshot.app.bundleIdentifier
        )
    }

    private func performContainingWebRowClick(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int
    ) throws -> Bool {
        guard
            button == .left,
            clickCount <= 1,
            let element = record.element,
            let targetFrame = record.localFrame
        else {
            return false
        }

        var current = element

        for _ in 0..<6 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            let rawActions = copyActions(for: parent) ?? []
            let candidate = ElementRecord(
                index: -1,
                identifier: nil,
                element: parent,
                localFrame: localFrame(of: parent, windowBounds: snapshot.windowBounds),
                rawActions: rawActions,
                prettyActions: rawActions
            )

            if isLikelyContainingWebRowAction(targetFrame: targetFrame, candidate: candidate),
               !isLikelySyntheticSideAction(candidate, in: record),
               try performAction(named: kAXPressAction as String, on: parent, availableActions: rawActions)
            {
                debugClickDecision("handled by containing web row \(clickDebugDescription(candidate))")
                return true
            }

            current = parent
        }

        return false
    }

    private func isLikelyContainingWebRowAction(
        targetFrame: CGRect,
        candidate: ElementRecord
    ) -> Bool {
        isLikelyContainingRowActionFrame(
            targetFrame: targetFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate)
        )
    }

    private func hasAncestorRole(_ role: String, of element: AXUIElement) -> Bool {
        var current = element

        for _ in 0..<12 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == role {
                return true
            }

            current = parent
        }

        return false
    }

    private func accessibilityLabels(for element: AXUIElement?) -> [String] {
        guard let element else {
            return []
        }

        return [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXValueAttribute as String,
            "AXIdentifier"
        ].compactMap { attribute in
            stringValue(of: element, attribute: attribute)
        }
    }

    private func clickFrame(for record: ElementRecord, snapshot: AppSnapshot) -> CGRect? {
        guard let frame = record.localFrame else {
            return nil
        }

        guard
            !record.isSyntheticText,
            let element = record.element,
            stringValue(of: element, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
            let rowFrame = containingRowFrame(for: element, textFrame: frame, windowBounds: snapshot.windowBounds)
        else {
            return frame
        }

        return rowFrame
    }

    private func containingRowFrame(for element: AXUIElement, textFrame: CGRect, windowBounds: CGRect?) -> CGRect? {
        let textCenter = CGPoint(x: textFrame.midX, y: textFrame.midY)
        var current = element

        for _ in 0..<4 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if let frame = localFrame(of: parent, windowBounds: windowBounds),
               frame.insetBy(dx: -2, dy: -2).contains(textCenter),
               frame.width >= textFrame.width + 40,
               frame.height >= textFrame.height,
               frame.height <= max(textFrame.height * 4, 96)
            {
                return frame
            }

            current = parent
        }

        return nil
    }

    private func copyActions(for element: AXUIElement) -> [String]? {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success else {
            return nil
        }

        return actions as? [String]
    }

    private func copyChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let value else {
            return []
        }

        return value as? [AXUIElement] ?? []
    }

    private func copyParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }

    private func localFrame(of element: AXUIElement, windowBounds: CGRect?) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard
            positionResult == .success,
            sizeResult == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        guard let windowBounds else {
            return frame
        }

        return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
    }

    private func globalPoint(for record: ElementRecord, snapshot: AppSnapshot) throws -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: CGPoint(x: frame.midX, y: frame.midY)
        )
    }

    private func clickPoint(for record: ElementRecord, snapshot: AppSnapshot) -> CGPoint? {
        clickActionPoints(for: record, snapshot: snapshot).first ?? localCenter(for: record)
    }

    private func screenshotToGlobalPoint(snapshot: AppSnapshot, x: Double, y: Double) throws -> CGPoint {
        try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: try screenshotPixelToWindowPointInSnapshot(
                snapshot: snapshot,
                point: CGPoint(x: x, y: y)
            )
        )
    }

    private func screenshotPixelToWindowPointInSnapshot(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        if snapshot.screenshotData == nil, let note = snapshot.screenshotNote {
            throw ComputerUseError.stateUnavailable(note + "; coordinate input requires a delivered screenshot")
        }
        return screenshotPixelToWindowPoint(
            point,
            screenshotPixelSize: screenshotPixelSize(snapshot: snapshot),
            windowBounds: snapshot.windowBounds
        )
    }

    private func screenshotPixelSize(snapshot: AppSnapshot) -> CGSize? {
        guard
            let screenshotData = snapshot.screenshotData,
            let imageSource = CGImageSourceCreateWithData(screenshotData as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            return nil
        }

        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private func windowPointToGlobalPoint(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        guard let windowBounds = snapshot.windowBounds else {
            let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
            throw ComputerUseError.stateUnavailable("No window bounds are available for \(appReference). Run get_app_state after bringing the app on screen.")
        }

        return globalPointFromWindowPoint(point, windowBounds: windowBounds)
    }

    private func fixtureIdentifier(at point: CGPoint, snapshot: AppSnapshot) throws -> String {
        let candidates = snapshot.elements.values
            .filter { $0.identifier != nil && ($0.localFrame?.contains(point) ?? false) }
            .sorted { lhs, rhs in
                let lhsArea = (lhs.localFrame?.width ?? 0) * (lhs.localFrame?.height ?? 0)
                let rhsArea = (rhs.localFrame?.width ?? 0) * (rhs.localFrame?.height ?? 0)
                return lhsArea < rhsArea
            }

        guard let identifier = candidates.first?.identifier else {
            throw ComputerUseError.invalidArguments("No fixture element contains coordinate (\(Int(point.x)), \(Int(point.y)))")
        }

        return identifier
    }

    private func visualCursorTarget(for record: ElementRecord, snapshot: AppSnapshot) -> VisualCursorTarget? {
        makeVisualCursorTarget(
            localFrame: record.localFrame,
            windowBounds: snapshot.windowBounds,
            targetWindowID: snapshot.targetWindowID,
            targetWindowLayer: snapshot.targetWindowLayer
        )
    }

    private func fixtureVisualCursorTarget(identifier: String, snapshot: AppSnapshot) -> VisualCursorTarget? {
        let record = snapshot.elements.values.first { $0.identifier == identifier }
        return record.flatMap { visualCursorTarget(for: $0, snapshot: snapshot) }
    }

    private func moveVisualCursor(to target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.moveCursor(to: target.point, in: target.window)
        }
    }

    private func settleVisualCursor(at target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.settle(at: target.point, in: target.window)
        }
    }

    private func pulseVisualCursor(at target: VisualCursorTarget?, clickCount: Int, mouseButton: MouseButtonKind) {
        guard let target else {
            return
        }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.pulseClick(
                at: target.point,
                clickCount: clickCount,
                mouseButton: mouseButton,
                in: target.window
            )
        }
    }

    private func debugInputFallback(tool: String, targetDescription: String, snapshot: AppSnapshot) {
        guard inputFallbackDebugEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
        fputs(
            "[open-computer-use] global pointer fallback tool=\(tool) app=\(appReference) target=\(targetDescription)\n",
            stderr
        )
    }

    private func debugClickDecision(_ message: String) {
        guard inputFallbackDebugEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        fputs("[open-computer-use] click decision \(message)\n", stderr)
    }

    private func clickDebugDescription(_ record: ElementRecord) -> String {
        let role = record.element.flatMap { stringValue(of: $0, attribute: kAXRoleAttribute) } ?? "nil"
        let actions = record.rawActions.joined(separator: ",")
        let frame = record.localFrame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "nil"
        return "index=\(record.index) role=\(role) synthetic=\(record.isSyntheticText) actions=[\(actions)] frame=\(frame)"
    }

    private func integralScrollPageCount(_ pages: Double) -> Int? {
        let rounded = pages.rounded(.toNearestOrAwayFromZero)
        guard abs(pages - rounded) < 0.000001 else {
            return nil
        }
        return max(Int(rounded), 1)
    }

    private func performScrollEvent(
        at point: CGPoint,
        direction: String,
        pages: Double,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) {
            debugInputFallback(
                tool: "scroll",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.scrollGlobally(at: eventPoint, direction: direction, pages: pages)
            return
        }

        try performAppPostInput(snapshot: snapshot, points: [point]) {
            try InputSimulation.scrollTargeted(at: eventPoint, direction: direction, pages: pages, pid: snapshot.app.pid)
        }
    }

    private func performDragEvent(
        from start: CGPoint,
        to end: CGPoint,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws -> DragDeliveryPath {
        let eventStart = inputEventPoint(fromScreenStatePoint: start)
        let eventEnd = inputEventPoint(fromScreenStatePoint: end)
        let path = dragDeliveryPath(environment: ProcessInfo.processInfo.environment)

        switch path {
        case .global:
            debugInputFallback(
                tool: "drag",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.dragGlobally(from: eventStart, to: eventEnd)
        case .appPost:
            try performAppPostInput(snapshot: snapshot, points: [start, end]) {
                try InputSimulation.dragTargeted(from: eventStart, to: eventEnd, pid: snapshot.app.pid)
            }
        }

        return path
    }

    private func performAppPostInput(
        snapshot: AppSnapshot, points: [CGPoint], submit: () throws -> Void
    ) throws {
        try dispatchAppPostInput(
            policy: ExecutionPolicy.current(),
            validateReceiver: {
                try validateCoordinateAppPostTarget(validateWindow: {
                    for point in points {
                        try self.validateCoordinateSnapshot(at: point, snapshot: snapshot)
                    }
                }, readFocusedWindowMatch: {
                    try KeyboardReceiver.optionalFocusedWindowMatches(in: snapshot)
                })
            },
            submit: submit
        )
    }

    private func performNonAXClickFallback(
        at point: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let method = coordinateMouseMethod(
            button: button, clickCount: clickCount,
            globalEnabled: automaticForegroundClicksEnabled(environment: ProcessInfo.processInfo.environment)
        )
        InputDiagnostics.event("mouse_route_selected", ["route": method.rawValue])
        try validateCoordinateSnapshot(at: point, snapshot: snapshot, identityOnly: method == .global)
        guard let bounds = snapshot.windowBounds else {
            throw ComputerUseError.stateUnavailable("Coordinate window bounds are unavailable")
        }
        try performExplicitMouseClick(
            method: method, at: point,
            windowPoint: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY),
            button: button, clickCount: clickCount, targetDescription: targetDescription, snapshot: snapshot
        )
    }

    private func performExplicitMouseClick(
        method: ClickMethod,
        at point: CGPoint,
        windowPoint: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        switch method {
        case .appPost:
            debugClickDecision("requested=app_post executed=pid_post target=\(targetDescription)")
            try performAppPostInput(snapshot: snapshot, points: [point]) {
                try InputDiagnostics.input(route: method, point: eventPoint) {
                    try InputSimulation.clickTargeted(
                        at: eventPoint, button: button, clickCount: clickCount, pid: snapshot.app.pid
                    )
                }
            }
        case .skyClick:
            guard let windowBounds = snapshot.windowBounds, let windowID = snapshot.targetWindowID else {
                throw ComputerUseError.stateUnavailable(
                    "click_method 'sky_click' requires a current on-screen target window. Run get_app_state again."
                )
            }
            debugClickDecision("requested=sky_click executed=skylight_pid_post target=\(targetDescription)")
            try InputDiagnostics.input(route: method, point: eventPoint) {
                try InputSimulation.clickWithSkyLight(
                    at: eventPoint, windowPoint: windowPoint, windowBounds: windowBounds,
                    windowID: windowID, clickCount: clickCount, pid: snapshot.app.pid, button: button
                )
            }
        case .global:
            guard foregroundClicksEnabled(environment: ProcessInfo.processInfo.environment) else {
                throw ComputerUseError.message("Foreground click is not enabled for this process")
            }
            try performForegroundClick(at: point, button: button, clickCount: clickCount, snapshot: snapshot)
        case .auto, .accessibility:
            throw ComputerUseError.message(
                "click_method '\(method.rawValue)' is not a direct mouse event method"
            )
        }
    }

    private func performForegroundClick(
        at point: CGPoint, button: MouseButtonKind, clickCount: Int, snapshot: AppSnapshot,
        authorization: ForegroundClickAuthorization? = nil
    ) throws {
        try dispatchForegroundClick(
            authorization: authorization,
            validateTarget: { try self.validateCoordinateSnapshot(at: point, snapshot: snapshot, identityOnly: true) },
            prepare: {
                guard let window = snapshot.windowElement else {
                    throw ComputerUseError.stateUnavailable("Snapshot window is unavailable; observe again")
                }
                try InputSimulation.prepareWindowForForegroundClick(snapshot.app, window: window, authorization: authorization)
            },
            validateReceiver: {
                guard let window = snapshot.windowElement,
                      InputSimulation.isForegroundWindow(snapshot.app, window: window) else {
                    throw ComputerUseError.stateUnavailable("Foreground window changed; observe again before clicking")
                }
                // 激活可能切换 Space、移动窗口或打开弹窗，旧截图坐标不能直接复用。
                try self.validateCoordinateSnapshot(at: point, snapshot: snapshot, requireUnoccludedPoint: true)
            },
            submit: {
                try InputDiagnostics.input(route: .global, point: point) {
                    try InputSimulation.clickGlobally(at: inputEventPoint(fromScreenStatePoint: point), button: button, clickCount: clickCount, authorization: authorization)
                }
            }
        )
    }

    private func snapshotResult(
        for snapshot: AppSnapshot, style: SnapshotTextStyle, reportMissingPopups: Bool = false
    ) -> ToolCallResult {
        LiveWindowPreview.publish(snapshot)
        var content = [ToolResultContentItem.text(snapshot.renderedText(style: style))]
        if let note = snapshot.screenshotNote { content.append(.text(note)) }
        if let screenshotData = snapshot.screenshotData {
            content.append(.screenshotImage(screenshotData))
        }
        // 主图坐标保持不变；独立弹层以相邻说明和独立图片交付，避免误判点击无效。
        let observation = snapshotDependencies.captureHoverPopups(snapshot, reportMissingPopups ? .explicit : .ordinary)
        guard !observation.isIncomplete else {
            hoverPopupCache.clear()
            content.append(.text(HoverPopupCaptureResult.incompleteNote))
            return ToolCallResult(content: content)
        }
        let popups = observation.popups
        hoverPopupCache.record(popups, snapshot: snapshot, now: ProcessInfo.processInfo.systemUptime)
        content.append(contentsOf: popups.flatMap(\.content))
        if reportMissingPopups, popups.isEmpty {
            content.append(.text(HoverPopupObservation.unavailableNote))
        }
        return ToolCallResult(content: content)
    }
}
