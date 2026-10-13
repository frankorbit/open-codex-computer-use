import Foundation

let applicationWindowTimeoutMessage = "Application started, but its window was not ready within 3 seconds "
    + "(cgWindowNotFound). Observe again to recover; do not repeat launch/reopen."

/// 只用于一次 launch/reopen 成功后的窗口准备；不改变普通观察的重试策略。
struct ApplicationWindowWait {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    var checkCancellation: () throws -> Void = { try Task.checkCancellation() }

    func run(validate: () throws -> Void, probe: (TimeInterval) throws -> Bool) throws {
        let deadline = now() + 3
        while now() < deadline {
            try checkCancellation()
            try validate()
            guard now() < deadline else { break }
            let ready = try probe(deadline)
            try checkCancellation()
            try validate()
            // 慢探测不能在截止时间后发布就绪结果。
            guard now() < deadline else { break }
            if ready { return }
            sleep(min(0.1, max(0, deadline - now())))
        }
        try checkCancellation()
        try validate()
        throw ComputerUseError.stateUnavailable(applicationWindowTimeoutMessage)
    }
}
