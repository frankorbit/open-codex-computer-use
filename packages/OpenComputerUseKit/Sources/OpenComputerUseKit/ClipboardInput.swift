import AppKit
import Foundation

/// 只保存原始格式字节；内容不进入日志或错误文本。
struct ClipboardItem: CustomStringConvertible {
    var values: [NSPasteboard.PasteboardType: Data]
    var description: String {
        "ClipboardItem(<redacted>)"
    }
}

protocol ClipboardStore {
    var changeCount: Int { get }
    func readItems() throws -> [ClipboardItem]
    func clear() -> Int
    func write(_ items: [ClipboardItem]) -> Bool
    func owns(_ token: String) -> Bool
    func stage(_ text: String, token: String) -> Bool
}

extension ClipboardStore {
    func stage(_ text: String, token: String) -> Bool {
        write([ClipboardItem(values: [.string: Data(text.utf8), ClipboardInput.ownerType: Data(token.utf8)])])
    }
}

final class SystemClipboardStore: ClipboardStore {
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func readItems() throws -> [ClipboardItem] {
        var size = 0
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= 64
        else { throw ClipboardInput.failure("Clipboard has too many items; no input was sent.") }
        return try items.map { item in
            guard item.types.count <= 128 else {
                throw ClipboardInput.failure("Clipboard has too many formats; no input was sent.")
            }
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw ClipboardInput.failure("Cannot preserve a clipboard format; no input was sent.")
                }
                size += data.count
                guard size <= 16 * 1024 * 1024 else {
                    throw ClipboardInput.failure("Clipboard exceeds preservation budget; no input was sent.")
                }
                values[type] = data
            }
            return ClipboardItem(values: values)
        }
    }

    func clear() -> Int {
        pasteboard.clearContents()
    }

    func write(_ items: [ClipboardItem]) -> Bool {
        if items.isEmpty { return true }
        var objects: [NSPasteboardItem] = []
        for item in items {
            let object = NSPasteboardItem()
            for (type, data) in item.values {
                guard object.setData(data, forType: type) else { return false }
            }
            objects.append(object)
        }
        return pasteboard.writeObjects(objects)
    }

    func owns(_ token: String) -> Bool {
        pasteboard.string(forType: ClipboardInput.ownerType) == token
    }
}

enum ClipboardInput {
    static let ownerType = NSPasteboard.PasteboardType("org.opencomputeruse.paste-owner")
    private static let lock = NSLock()

    static func failure(_ message: String) -> ComputerUseError {
        .stateUnavailable(message)
    }

    static func paste(
        _ text: String, validateReceiver: () throws -> Void,
        sendPaste: (() throws -> Void, () -> Void) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try transact(
            text,
            store: SystemClipboardStore(pasteboard: .general),
            validateReceiver: validateReceiver,
            sendPaste: sendPaste
        )
    }

    static func transact(
        _ text: String, store: any ClipboardStore, validateReceiver: () throws -> Void,
        sendPaste: (() throws -> Void, () -> Void) throws -> Void
    ) throws {
        guard text.utf8.count <= 8 * 1024 * 1024 else {
            throw failure("Paste text exceeds 8 MiB; no input was sent.")
        }
        try validateReceiver()
        let ownership = try prepare(text, store: store, validateReceiver: validateReceiver)
        var attempted = false
        do {
            try ownership.requireOwnership()
            try validateReceiver()
            try withoutActuallyEscaping(validateReceiver) { validate in
                try sendPaste({
                    try validate()
                    try ownership.requireOwnership()
                }, { attempted = true })
            }
        } catch {
            // 只有实际提交之前的失败才能恢复；任意读取回执都不能证明目标已消费。
            if !attempted {
                try ownership.restore()
                throw error
            }
            throw failure(
                "Paste dispatch was not confirmed; input may have occurred. Clipboard text was retained. "
                    + "Observe before continuing; do not replay."
            )
        }
        // 异步目标仍可能读取剪贴板，提交后不恢复旧数据，也不覆盖用户的后续复制。
    }

    private struct Ownership {
        let store: any ClipboardStore
        let original: [ClipboardItem]
        let token: String
        let stagedCount: Int

        func requireOwnership() throws {
            guard store.changeCount == stagedCount, store.owns(token) else {
                throw failure("Clipboard changed before paste; no input was sent.")
            }
        }

        func restore() throws {
            // 用户在执行期间复制新内容时，不用旧快照覆盖它。系统不提供原子 CAS。
            guard store.changeCount == stagedCount, store.owns(token) else { return }
            let count = store.clear()
            guard store.changeCount == count else { return }
            guard store.write(original) else {
                throw failure("Clipboard restoration failed; no input was sent.")
            }
        }
    }

    private static func prepare(
        _ text: String, store: any ClipboardStore, validateReceiver: () throws -> Void
    ) throws -> Ownership {
        let originalCount = store.changeCount
        let original = try store.readItems()
        try validateReceiver()
        guard store.changeCount == originalCount else {
            throw failure("Clipboard changed during capture; no input was sent.")
        }
        let token = UUID().uuidString
        let clearedCount = store.clear()
        guard store.changeCount == clearedCount else {
            throw failure("Clipboard changed while preparing paste; no input was sent.")
        }
        guard store.stage(text, token: token) else {
            if store.owns(token) {
                try Ownership(
                    store: store, original: original, token: token, stagedCount: store.changeCount
                ).restore()
            } else if store.changeCount == clearedCount {
                guard store.write(original) else {
                    throw failure("Clipboard staging and restoration failed; no input was sent.")
                }
            }
            throw failure("Clipboard staging failed; no input was sent.")
        }
        return Ownership(store: store, original: original, token: token, stagedCount: store.changeCount)
    }
}
