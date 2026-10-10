import ApplicationServices
import Foundation

struct SnapshotDependencies {
    var resolve: (String) throws -> RunningAppDescriptor
    var build: (RunningAppDescriptor, SnapshotTextLimit, AccessibilityTreeLimits, SnapshotRecoveryPolicy) throws
        -> AppSnapshot
    var captureHoverPopups: (AppSnapshot) -> [HoverPopupObservation] = HoverPopupObservation.capture
    var parkWindow: (CGWindowID, pid_t, AXUIElement) throws -> Void = { windowID, pid, window in
        try AgentDisplay.shared.park(windowID: windowID, pid: pid, window: window)
    }

    var restoreWindows: (pid_t) throws -> Void = { pid in
        try AgentDisplay.shared.restoreAll(pid: pid)
    }

    static var live: SnapshotDependencies {
        SnapshotDependencies(
            resolve: AppDiscovery.resolve,
            build: { app, textLimit, treeLimits, recoveryPolicy in
                try SnapshotBuilder.build(
                    for: app,
                    textLimit: textLimit,
                    treeLimits: treeLimits,
                    recoveryPolicy: recoveryPolicy
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

    init(snapshots: [String: AppSnapshot] = [:]) {
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

    mutating func recordObservation(_ snapshot: AppSnapshot, for query: String) {
        let target = bind(query, to: snapshot.app)
        snapshotsByTarget[target] = snapshot
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
