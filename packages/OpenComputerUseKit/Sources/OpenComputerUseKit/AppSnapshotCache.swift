import AppKit
import ApplicationServices
import Foundation

struct SnapshotProcessIdentity: Equatable {
    let pid: pid_t
    let launchDate: Date

    static func current(for pid: pid_t) -> Self? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, let launchDate = app.launchDate else { return nil }
        return Self(pid: pid, launchDate: launchDate)
    }

    static func bound(to app: RunningAppDescriptor) -> Self? {
        // 绑定证据来自原 descriptor，不能按 PID 重查后误绑定到复用该 PID 的新进程。
        guard app.runningApplication.processIdentifier == app.pid,
              !app.runningApplication.isTerminated,
              let launchDate = app.runningApplication.launchDate else { return nil }
        return Self(pid: app.pid, launchDate: launchDate)
    }
}

struct SnapshotObservationBinding {
    let app: RunningAppDescriptor
    let processIdentity: SnapshotProcessIdentity?

    func validate(current: SnapshotProcessIdentity?) throws {
        guard let processIdentity, processIdentity.pid == app.pid, current == processIdentity else {
            throw ComputerUseError.stateUnavailable(
                "Bound app process is unavailable or changed. "
                    + "Run get_app_state to explicitly rebind; no input was sent."
            )
        }
    }
}

struct SnapshotDependencies {
    var resolve: (String) throws -> RunningAppDescriptor
    var build: (RunningAppDescriptor, SnapshotTextLimit, AccessibilityTreeLimits, SnapshotRecoveryPolicy, SnapshotObservationOptions) throws
        -> AppSnapshot
    var processIdentity: (pid_t) -> SnapshotProcessIdentity? = SnapshotProcessIdentity.current
    var bindingIdentity: (RunningAppDescriptor) -> SnapshotProcessIdentity? = SnapshotProcessIdentity.bound
    var prepareOpen: (String) throws -> ApplicationOpeningRequest = AppDiscovery.prepareOpen
    var openingWindowWait = ApplicationWindowWait()
    var openingWindowReady: (RunningAppDescriptor, TimeInterval) throws -> Bool = SnapshotBuilder.openingWindowReady
    var captureHoverPopups: (AppSnapshot, HoverPopupObservationMode) -> HoverPopupCaptureResult
        = HoverPopupObservation.capture
    var parkWindow: (CGWindowID, pid_t, AXUIElement) throws -> Void = { windowID, pid, window in
        try AgentDisplay.shared.park(windowID: windowID, pid: pid, window: window)
    }

    var restoreWindows: (pid_t) throws -> Void = { pid in
        try AgentDisplay.shared.restoreAll(pid: pid)
    }

    static var live: SnapshotDependencies {
        SnapshotDependencies(
            resolve: AppDiscovery.resolve,
            build: { app, textLimit, treeLimits, recoveryPolicy, observation in
                try SnapshotBuilder.build(
                    for: app,
                    textLimit: textLimit,
                    treeLimits: treeLimits,
                    recoveryPolicy: recoveryPolicy,
                    observation: observation
                )
            }
        )
    }
}

struct AppSnapshotCache {
    private enum Target: Hashable {
        case bundle(String)
        case process(pid_t)

        init(_ app: RunningAppDescriptor) {
            if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
                self = .bundle(AppSnapshotCache.normalized(bundleIdentifier))
            } else {
                self = .process(app.pid)
            }
        }
    }

    static let observationRequiredMessage = "No valid snapshot is available. "
        + "Run get_app_state successfully before sending input."

    private var targetsByAlias: [String: Target] = [:]
    private var snapshotsByTarget: [Target: AppSnapshot] = [:]
    // 只保留进程绑定证据；失效快照的 AX 对象、图片与输入索引不保留。
    private var observationBindingsByTarget: [Target: SnapshotObservationBinding] = [:]
    private var pendingInitializations: Set<ApplicationOpeningIdentity> = []
    private let bindingIdentity: (RunningAppDescriptor) -> SnapshotProcessIdentity?

    init(
        snapshots: [String: AppSnapshot] = [:],
        bindingIdentity: @escaping (RunningAppDescriptor) -> SnapshotProcessIdentity? = SnapshotProcessIdentity.bound
    ) {
        self.bindingIdentity = bindingIdentity
        for (query, snapshot) in snapshots.sorted(by: { $0.key < $1.key }) {
            recordObservation(snapshot, for: query)
        }
    }

    func snapshot(for query: String) throws -> AppSnapshot {
        guard let target = targetsByAlias[Self.normalized(query)], let snapshot = snapshotsByTarget[target] else {
            throw ComputerUseError.stateUnavailable(Self.observationRequiredMessage)
        }
        return snapshot
    }

    func observationBinding(for query: String) -> SnapshotObservationBinding? {
        guard let target = targetsByAlias[Self.normalized(query)] else { return nil }
        return observationBindingsByTarget[target]
    }

    mutating func recordObservation(_ snapshot: AppSnapshot, for query: String) {
        let target = bind(query, to: snapshot.app)
        snapshotsByTarget[target] = snapshot
        if let identity = ApplicationOpeningIdentity(snapshot.app) {
            pendingInitializations.remove(identity)
        }
    }

    func hasPendingInitialization(for identity: ApplicationOpeningIdentity) -> Bool {
        pendingInitializations.contains(identity)
    }

    mutating func beginInitialization(for identity: ApplicationOpeningIdentity, query: String) {
        pendingInitializations.insert(identity)
        // 冷启动的新别名可能尚未绑定，但同一应用的旧快照仍必须失效。
        snapshotsByTarget = snapshotsByTarget.filter { ApplicationOpeningIdentity($0.value.app) != identity }
        invalidate(query: query)
    }

    mutating func finishInitialization(for identity: ApplicationOpeningIdentity) {
        pendingInitializations.remove(identity)
    }

    mutating func recordReadBack(_ snapshot: AppSnapshot, for query: String) throws {
        let target = Target(snapshot.app)
        // 动作回读不能解除观察失败，也不能把输入授权转移给另一个目标。
        guard targetsByAlias[Self.normalized(query)] == target, snapshotsByTarget[target] != nil else {
            throw ComputerUseError.stateUnavailable(Self.observationRequiredMessage)
        }
        snapshotsByTarget[target] = snapshot
    }

    mutating func invalidate(query: String, resolvedApp: RunningAppDescriptor? = nil) {
        let target = resolvedApp.map { bind(query, to: $0) } ?? targetsByAlias[Self.normalized(query)]
        if let target {
            snapshotsByTarget.removeValue(forKey: target)
        }
        // 保留别名关联，使 resolve 失败和重复失败仍能定位同一目标；未知名称不猜测匹配。
    }

    private mutating func bind(_ query: String, to app: RunningAppDescriptor) -> Target {
        let target = Target(app)
        targetsByAlias[Self.normalized(query)] = target
        observationBindingsByTarget[target] = SnapshotObservationBinding(
            app: app, processIdentity: bindingIdentity(app)
        )
        for alias in [app.name, app.bundleIdentifier ?? ""].map(Self.normalized) where !alias.isEmpty {
            // 同名 App 不覆盖已知映射；只有显式解析的 query 可以重新绑定。
            if targetsByAlias[alias] == nil {
                targetsByAlias[alias] = target
            }
        }
        return target
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
