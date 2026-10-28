import Foundation

enum HoverPopupObservationMode {
    case ordinary
    case explicit

    var duration: TimeInterval {
        self == .ordinary ? 0.2 : 0.8
    }
}

struct HoverPopupBudget {
    let deadline: TimeInterval

    init(duration: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
    }

    var remaining: TimeInterval {
        max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    var expired: Bool {
        remaining <= 0
    }
}

struct HoverPopupCaptureResult {
    var popups: [HoverPopupObservation] = []
    var isIncomplete = false

    static var incomplete: Self {
        Self(isIncomplete: true)
    }

    static let incompleteNote = "Popup observation incomplete: the shared capture budget, worker availability, "
        + "AX limits or window verification prevented a complete observation. No popup input tokens were issued. "
        + "This does not prove no popup exists; explicitly observe again if needed."
}

/// 进程共用一个槽位；超时只放弃结果，不能把仍在系统调用中的 worker 当作已结束。
final class HoverPopupCaptureWorker: @unchecked Sendable {
    static let shared = HoverPopupCaptureWorker()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.ocu.popup-observation", qos: .userInitiated)
    private var active: Work?

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    /// 闭包只在 worker 执行；调用方不得捕获 service、缓存或请求诊断 owner。
    private final class Work: @unchecked Sendable {
        let operation: () -> HoverPopupCaptureResult
        let finished = DispatchSemaphore(value: 0)
        var abandoned = false
        var result: HoverPopupCaptureResult?

        init(operation: @escaping () -> HoverPopupCaptureResult) {
            self.operation = operation
        }
    }

    func capture(
        budget: HoverPopupBudget, operation: @escaping () -> HoverPopupCaptureResult
    ) -> HoverPopupCaptureResult {
        lock.lock()
        guard active == nil, !budget.expired else {
            let reason: HoverPopupDiagnostics.Reason = active == nil ? .deadlineExpired : .workerBusy
            lock.unlock()
            HoverPopupDiagnostics.record(reason)
            return .incomplete
        }
        let work = Work(operation: operation)
        active = work
        queue.async {
            let result = budget.expired ? .incomplete : autoreleasepool { work.operation() }
            self.lock.lock()
            if !work.abandoned, !budget.expired { work.result = result }
            self.active = nil
            work.finished.signal()
            self.lock.unlock()
        }
        lock.unlock()
        // 单调时钟等待，不同步派发主线程，也不运行嵌套 RunLoop。
        _ = work.finished.wait(timeout: .now() + budget.remaining)
        lock.lock()
        defer { lock.unlock() }
        guard !budget.expired, let result = work.result else {
            work.abandoned = true
            work.result = nil
            HoverPopupDiagnostics.record(.deadlineExpired)
            return .incomplete
        }
        return result.isIncomplete ? .incomplete : result
    }
}
