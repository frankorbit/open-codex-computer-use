import AppKit
import Foundation

/// 可注入系统边界；测试使用相同的焦点交接、到期和失败清理流程。
struct SkyClickMenuFocusBackend {
    var now: () -> TimeInterval
    var foregroundPID: () -> pid_t?
    var launchDate: (pid_t) -> Date?
    var rootExists: (SkyClickTarget) -> Bool
    var popupIDs: (SkyClickTarget) -> Set<CGWindowID>
    var begin: (SkyClickTarget) throws -> SkyLightSyntheticFocusContext
    var makeKey: (SkyLightSyntheticFocusContext) throws -> Void
    var end: (SkyLightSyntheticFocusContext) throws -> Void
    var wait: (TimeInterval) -> Void
    var schedule: (TimeInterval, @escaping @Sendable () -> Void) -> Void

    static var live: Self {
        Self(
            now: { ProcessInfo.processInfo.systemUptime },
            foregroundPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            launchDate: { NSRunningApplication(processIdentifier: $0)?.launchDate },
            rootExists: { target in
                guard
                    let app = NSRunningApplication(processIdentifier: target.pid),
                    !app.isTerminated, !app.isHidden else { return false }
                return windows().contains {
                    $0.windowID == target.windowID && $0.pid == target.pid && $0.bounds == target.windowBounds
                }
            },
            popupIDs: { target in
                let rows = windows()
                guard let root = rows.firstIndex(where: { $0.windowID == target.windowID && $0.pid == target.pid })
                else { return [] }
                return Set(rows[..<root].filter {
                    $0.pid == target.pid && $0.isVisible && $0.layer >= 0
                        && HoverPopupObservation.geometricallyRelated($0.bounds, target.windowBounds)
                }.map(\.windowID))
            },
            begin: { try SkyLightSPI.shared.beginSyntheticTargetFocus(targetPID: $0.pid, targetWindowID: $0.windowID) },
            makeKey: { try SkyLightSPI.shared.makeSyntheticTargetWindowKey($0) },
            end: { try SkyLightSPI.shared.endSyntheticTargetFocus($0) },
            wait: { Thread.sleep(forTimeInterval: $0) },
            schedule: { delay, action in DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + delay,
                execute: action
            ) }
        )
    }

    private static func windows() -> [HoverPopupObservation.Window] {
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap(HoverPopupObservation.windowInfo)
    }
}

/// 一个 service 拥有一份有界菜单交互状态；跨请求只保留目标应用的合成焦点。
/// 所有读写与定时清理共用鼠标派发锁，不能在 mouse-down/up 中途释放焦点。
final class SkyClickMenuFocus: @unchecked Sendable {
    @TaskLocal static var current: SkyClickMenuFocus?

    private struct Lease {
        let id = UUID()
        let diagnosticID = InputDiagnostics.operationID ?? UUID().uuidString
        let target: SkyClickTarget
        let launchDate: Date
        let context: SkyLightSyntheticFocusContext
        let popupIDs: Set<CGWindowID>
        let expiresAt: TimeInterval
    }

    /// 同一进程只能有一个未结束的合成菜单焦点；旧会话的定时器不能关闭新会话的菜单。
    private final class Ownership: @unchecked Sendable {
        weak var owner: SkyClickMenuFocus?
    }

    private static let ownership = Ownership()
    private let cleanupDiagnosticID = UUID().uuidString
    private let retainsMenus: Bool
    private let backend: SkyClickMenuFocusBackend
    private var lease: Lease?
    private var query: String?
    private static let lifetime: TimeInterval = 30
    private static let keyWindowSettle: TimeInterval = 0.100

    init(backend: SkyClickMenuFocusBackend = .live, retainsMenus: Bool = true) {
        self.retainsMenus = retainsMenus
        self.backend = backend
    }

    func beginRequest(app: String?) throws {
        try SkyClickDispatcher.synchronized {
            if query != app { try release() }
            query = app
            if let lease, !isLive(lease) { try release() }
        }
    }

    /// 连续动作期间暂停定时清理；按回读时的实际弹层交接焦点，不把每次动作当成交互结束。
    func withInteraction<T>(_ action: () throws -> T) throws -> T {
        try SkyClickDispatcher.synchronized {
            if let owner = Self.ownership.owner, owner !== self { try owner.release() }
            if let lease, !isLive(lease) { try release() }
            let pending = lease
            let before = pending.map { backend.popupIDs($0.target) } ?? []
            do {
                let result = try action()
                if let pending, lease?.id == pending.id {
                    try reconcileAfterInteraction(pending, before: before)
                }
                return result
            } catch {
                try release()
                throw error
            }
        }
    }

    private func reconcileAfterInteraction(_ pending: Lease, before: Set<CGWindowID>) throws {
        guard
            backend.now() < pending.expiresAt, backend.launchDate(pending.target.pid) == pending.launchDate,
            backend.rootExists(pending.target), backend.foregroundPID() != pending.target.pid else {
            try release()
            return
        }
        let current = backend.popupIDs(pending.target)
        // 只继承原弹层或本动作新出现的候选，不能用原先无关的同应用窗口续租。
        let candidates = current.intersection(pending.popupIDs).union(current.subtracting(before))
        guard !candidates.isEmpty else {
            try release()
            return
        }
        let updated = Lease(
            target: pending.target, launchDate: pending.launchDate, context: pending.context,
            popupIDs: candidates, expiresAt: pending.expiresAt
        )
        lease = updated
        // 更新代际但不延长原到期时间；状态查询或循环滚动不能无限占用焦点。
        scheduleCheck(id: updated.id)
    }

    func cancel() throws {
        try SkyClickDispatcher.synchronized { try release() }
    }

    func cancelAfterFailure() {
        do { try cancel() } catch {
            InputDiagnostics.$operationID.withValue(cleanupDiagnosticID) {
                InputDiagnostics.event("menu_focus_cleanup_failed", ["effect": "unknown"])
            }
        }
    }

    /// 凭证仍由弹层快照负责；这里的窗口候选只能延长焦点，绝不授权点击。
    func deliver(
        target: SkyClickTarget,
        profile: SkyClickProfile,
        button: MouseButtonKind,
        clickCount: Int,
        submit: () throws -> Void
    ) throws {
        if let owner = Self.ownership.owner, owner !== self { try owner.release() }
        Self.ownership.owner = self
        let reused: Lease?
        if
            let pending = lease, profile == .popup, pending.target.pid == target.pid,
            pending.popupIDs.contains(target.windowID), isLive(pending) {
            reused = pending
            lease = nil
        } else {
            try release()
            reused = nil
        }
        Self.ownership.owner = self
        if backend.foregroundPID() == target.pid {
            // 用户已把目标带到前台时不能发送 deactivate；也无需建立后台焦点。
            try submit()
            return
        }

        let root = reused?.target ?? target
        let identity = backend.launchDate(root.pid)
        let before = backend.popupIDs(root)
        let context = try reused?.context ?? backend.begin(target)
        do {
            // 已打开的弹层不重新设 key，以免把焦点从弹层拉回主窗口。
            if reused == nil, profile == .standard, button == .left {
                try backend.makeKey(context)
                // key record 只保证入队；后台单击先让应用处理窗口焦点，再发送 down/up。
                // 不缩放这段准备时间，不影响双击节奏、弹层续点或只读观察。
                if clickCount == 1 {
                    backend.wait(Self.keyWindowSettle)
                    guard backend.rootExists(target), backend.launchDate(root.pid) == identity else {
                        throw ComputerUseError.stateUnavailable(
                            "sky_click target changed during key-window preparation. Run get_app_state again."
                        )
                    }
                }
            }
            try submit()
        } catch {
            if backend.launchDate(root.pid) == identity { try end(context, pid: root.pid) }
            throw error
        }

        let mayRetain = retainsMenus && button == .left && clickCount == 1
            && (profile == .standard || reused != nil)
        if
            mayRetain, let identity,
            retainIfNeeded(root: root, identity: identity, context: context, before: before, reusing: reused != nil) {
            return
        }
        backend.wait(0.100 * InputTiming.skyClickDelayScale)
        try end(context, pid: root.pid)
    }

    private func retainIfNeeded(
        root: SkyClickTarget,
        identity: Date,
        context: SkyLightSyntheticFocusContext,
        before: Set<CGWindowID>,
        reusing: Bool
    ) -> Bool {
        // 只给点击后的异步菜单创建一个有界等待；普通状态读取不进入此循环。
        var candidates: Set<CGWindowID> = []
        for _ in 0 ..< 12 {
            let current = backend.popupIDs(root)
            candidates = reusing ? current : current.subtracting(before)
            if !candidates.isEmpty { break }
            backend.wait(0.01)
        }
        guard
            !candidates.isEmpty, backend.launchDate(root.pid) == identity, backend.rootExists(root),
            backend.foregroundPID() != root.pid else { return false }
        let retained = Lease(
            target: root,
            launchDate: identity,
            context: context,
            popupIDs: candidates,
            expiresAt: backend.now() + Self.lifetime
        )
        lease = retained
        InputDiagnostics.event("menu_focus_retained", ["popup_count": String(candidates.count)])
        scheduleCheck(id: retained.id)
        return true
    }

    private func isLive(_ lease: Lease) -> Bool {
        backend.now() < lease.expiresAt && backend.launchDate(lease.target.pid) == lease.launchDate
            && backend.rootExists(lease.target) && backend.foregroundPID() != lease.target.pid
            && !backend.popupIDs(lease.target).isDisjoint(with: lease.popupIDs)
    }

    private func scheduleCheck(id: UUID) {
        backend.schedule(0.25) { [weak self] in
            guard let self else { return }
            SkyClickDispatcher.synchronized {
                guard let current = self.lease, current.id == id else { return }
                if self.isLive(current) {
                    self.scheduleCheck(id: id)
                } else {
                    InputDiagnostics.$operationID.withValue(current.diagnosticID) {
                        InputDiagnostics.event("menu_focus_expired", [
                            "age_remaining": String(current.expiresAt - self.backend.now()),
                            "identity_matches": String(self.backend.launchDate(current.target.pid) == current
                                .launchDate),
                            "root_exists": String(self.backend.rootExists(current.target)),
                            "foreground_pid": self.backend.foregroundPID().map(String.init) ?? "unknown",
                            "popup_count": String(self.backend.popupIDs(current.target).count)
                        ])
                    }
                    do { try self.release() } catch {
                        InputDiagnostics.$operationID.withValue(current.diagnosticID) {
                            InputDiagnostics.event("menu_focus_cleanup_failed", ["effect": "unknown"])
                        }
                    }
                }
            }
        }
    }

    private func release() throws {
        if Self.ownership.owner === self { Self.ownership.owner = nil }
        guard let pending = lease else { return }
        lease = nil
        // 不能向 PID 复用后的进程或用户已激活的应用发送失焦事件。
        guard backend.launchDate(pending.target.pid) == pending.launchDate else { return }
        try end(pending.context, pid: pending.target.pid)
    }

    private func end(_ context: SkyLightSyntheticFocusContext, pid: pid_t) throws {
        guard backend.foregroundPID() != pid else { return }
        do { try backend.end(context) } catch {
            throw ComputerUseError.message(
                "sky_click could not release synthetic focus; input effect and focus state are unknown. "
                    + "Observe before further input; do not replay."
            )
        }
    }
}
