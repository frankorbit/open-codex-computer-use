import ApplicationServices
import Foundation

/// 接收者校验独立于观察设置的进程级短超时；整个读取共享既有输入预算，不重试 AX 调用。
struct KeyboardReceiverAXReader {
    private let deadline: TimeInterval
    private let now: () -> TimeInterval
    private let checkCancellation: () throws -> Void
    private let setTimeout: (AXUIElement, Float) -> AXError
    private let copyValue: (AXUIElement, String) -> (AXError, CFTypeRef?)

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() },
        setTimeout: @escaping (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
        copyValue: @escaping (AXUIElement, String) -> (AXError, CFTypeRef?) = { source, attribute in
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(source, attribute as CFString, &value)
            return (result, value)
        }
    ) {
        self.now = now
        self.checkCancellation = checkCancellation
        self.setTimeout = setTimeout
        self.copyValue = copyValue
        deadline = now() + TimeInterval(axInputMessagingTimeout)
    }

    func query(
        _ source: AXUIElement, attribute: String, operation: String = "value",
        read: () -> AXError
    ) throws -> AXError {
        try checkCancellation()
        let start = now()
        let remaining = deadline - start
        guard remaining > 0 else { throw failure("Keyboard receiver validation timed out") }
        let timeout = Float(remaining)
        let prepared = setTimeout(source, timeout)
        guard prepared == .success else {
            throw failure("Keyboard receiver timeout setup failed (AXError \(prepared.rawValue))")
        }
        // 不改 system-wide 默认值；归还当前对象的超时设置，失败也必须停止输入。
        let result = read()
        let restored = setTimeout(source, 0)
        InputDiagnostics.event("keyboard_receiver_query", [
            "attribute": attribute, "operation": operation,
            "ax_result": String(result.rawValue), "timeout_ms": String(timeout * 1000),
            "duration_ms": String((now() - start) * 1000),
            "restore_result": String(restored.rawValue)
        ])
        try checkCancellation()
        guard restored == .success else {
            throw failure("Keyboard receiver timeout restore failed (AXError \(restored.rawValue))")
        }
        guard now() < deadline else { throw failure("Keyboard receiver validation timed out") }
        return result
    }

    func value(_ source: AXUIElement, attribute: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = try query(source, attribute: attribute) {
            let (result, copied) = copyValue(source, attribute)
            value = copied
            return result
        }
        switch result {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw failure("Live keyboard receiver query for \(attribute) failed (\(result.rawValue))")
        }
    }

    func element(_ source: AXUIElement, attribute: String) throws -> AXUIElement {
        guard let value = try value(source, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw failure("No live \(attribute) is available")
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func failure(_ reason: String) -> ComputerUseError {
        .stateUnavailable("\(reason). Observe the target before further input; no input was sent by this validation.")
    }
}
