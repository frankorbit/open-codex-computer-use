import AppKit
@testable import OpenComputerUseKit
import XCTest

private final class MemoryClipboard: ClipboardStore {
    var changeCount = 0
    var items: [ClipboardItem] = []
    var writes = 0
    var failWrite: Int?
    var partiallyFailStage = false
    func stage(_ text: String, token: String) -> Bool {
        let result = write([ClipboardItem(values: [
            .string: Data(text.utf8),
            ClipboardInput.ownerType: Data(token.utf8)
        ])])
        if partiallyFailStage { changeCount += 1; return false }
        return result
    }

    var onRead: (() -> Void)?
    func readItems() throws -> [ClipboardItem] {
        onRead?(); return items
    }

    func clear() -> Int {
        items = []; changeCount += 1; return changeCount
    }

    func write(_ items: [ClipboardItem]) -> Bool {
        writes += 1
        if writes == failWrite { return false }
        self.items = items
        return true
    }

    func owns(_ token: String) -> Bool {
        items.first?.values[ClipboardInput.ownerType] == Data(token.utf8)
    }

    func userCopy() {
        _ = clear(); items = [ClipboardItem(values: [.string: Data("user copy".utf8)])]
    }
}

final class ClipboardInputTests: XCTestCase {
    func testUnrelatedReadDoesNotRestoreClipboardBeforeDelayedTarget() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ocu-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let board = SystemClipboardStore(pasteboard: pasteboard)
        let original = ClipboardItem(values: [.string: Data("old".utf8), .rtf: Data(#"{\rtf1\ansi old}"#.utf8)])
        _ = board.clear()
        XCTAssertTrue(board.write([original]))

        try ClipboardInput.transact("中文 👩‍💻", store: board, validateReceiver: {}, sendPaste: { validate, willSubmit in
            try validate(); willSubmit()
            XCTAssertEqual(pasteboard.string(forType: .string), "中文 👩‍💻")
        })
        XCTAssertEqual(pasteboard.string(forType: .string), "中文 👩‍💻")
    }

    func testSubmittedPasteRetainsRequestedTextForAsynchronousTarget() throws {
        let board = MemoryClipboard()
        let original: [NSPasteboard.PasteboardType: Data] = [.string: Data("old".utf8), .rtf: Data([0, 1, 2])]
        board.items = [ClipboardItem(values: original), ClipboardItem(values: [.png: Data([3, 4])])]
        var sends = 0
        try ClipboardInput.transact("中文 Uber", store: board, validateReceiver: {}, sendPaste: { validate, willSubmit in
            try validate(); willSubmit()
            sends += 1
            XCTAssertEqual(board.items.first?.values[.string], Data("中文 Uber".utf8))
        })
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(board.items.first?.values[.string], Data("中文 Uber".utf8))
        XCTAssertEqual(board.writes, 1)
    }

    func testConcurrentCopyIsPreservedAfterPaste() throws {
        let board = MemoryClipboard()
        try ClipboardInput.transact("input", store: board, validateReceiver: {}, sendPaste: { validate, willSubmit in
            try validate(); willSubmit()
            board.userCopy()
        })
        XCTAssertEqual(board.items.first?.values[.string], Data("user copy".utf8))
        XCTAssertEqual(board.writes, 1)
    }

    func testChangedClipboardBeforeKeyIsNotPastedOrOverwritten() {
        let board = MemoryClipboard()
        var sends = 0
        XCTAssertThrowsError(try ClipboardInput
            .transact("input", store: board, validateReceiver: {}, sendPaste: { validate, willSubmit in
                board.userCopy()
                try validate(); willSubmit()
                sends += 1
            }))
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(board.items.first?.values[.string], Data("user copy".utf8))
    }

    func testUnknownResultRetainsRequestedClipboardWithoutRetry() {
        let board = MemoryClipboard()
        let original = Data("old".utf8)
        board.items = [ClipboardItem(values: [.string: original])]
        var sends = 0
        XCTAssertThrowsError(try ClipboardInput
            .transact("input", store: board, validateReceiver: {}, sendPaste: { validate, willSubmit in
                try validate(); willSubmit()
                sends += 1
                throw ComputerUseError.message("transport unknown")
            })) { error in
                XCTAssertTrue(error.localizedDescription.contains("input may have occurred"))
            }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(board.items.first?.values[.string], Data("input".utf8))
    }

    func testPreflightFailureDoesNotTouchClipboard() {
        let board = MemoryClipboard()
        XCTAssertThrowsError(try ClipboardInput.transact("input", store: board, validateReceiver: {
            throw ComputerUseError.stateUnavailable("stale window")
        }, sendPaste: { _, _ in XCTFail("must not send") }))
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertEqual(board.writes, 0)
    }

    func testCopyDuringCapturePreventsStaging() {
        let board = MemoryClipboard()
        board.onRead = { board.userCopy() }
        defer { board.onRead = nil }
        XCTAssertThrowsError(try ClipboardInput.transact(
            "input",
            store: board,
            validateReceiver: {},
            sendPaste: { _, _ in
                XCTFail("must not send")
            }
        ))
        XCTAssertEqual(board.writes, 0)
        XCTAssertEqual(board.items.first?.values[.string], Data("user copy".utf8))
    }

    func testStageFailureRestoresAndDoesNotSend() {
        let board = MemoryClipboard()
        board.items = [ClipboardItem(values: [.string: Data("old".utf8)])]
        board.failWrite = 1
        XCTAssertThrowsError(try ClipboardInput.transact(
            "input",
            store: board,
            validateReceiver: {},
            sendPaste: { _, _ in
                XCTFail("must not send")
            }
        ))
        XCTAssertEqual(board.items.first?.values[.string], Data("old".utf8))
    }

    func testPartialStageFailureRestoresOwnedClipboardWithoutSending() {
        let board = MemoryClipboard()
        board.items = [ClipboardItem(values: [.string: Data("old".utf8)])]
        board.partiallyFailStage = true
        XCTAssertThrowsError(try ClipboardInput.transact(
            "input",
            store: board,
            validateReceiver: {},
            sendPaste: { _, _ in
                XCTFail("must not send")
            }
        ))
        XCTAssertEqual(board.items.first?.values[.string], Data("old".utf8))
    }

    func testPreSubmissionDispatchFailureRestoresAllFormats() {
        let board = MemoryClipboard()
        let values: [NSPasteboard.PasteboardType: Data] = [.string: Data("old".utf8), .rtf: Data([1, 2])]
        board.items = [ClipboardItem(values: values)]
        XCTAssertThrowsError(try ClipboardInput.transact(
            "input",
            store: board,
            validateReceiver: {},
            sendPaste: { validate, _ in
                try validate()
                throw ComputerUseError.stateUnavailable("menu query denied before submission")
            }
        ))
        XCTAssertEqual(board.items.first?.values, values)
    }

    func testPreSubmissionRestorationFailureIsSurfacedWithoutInput() {
        let board = MemoryClipboard()
        board.failWrite = 2
        XCTAssertThrowsError(try ClipboardInput.transact(
            "input",
            store: board,
            validateReceiver: {},
            sendPaste: { _, _ in
                throw ComputerUseError.stateUnavailable("preflight failed")
            }
        )) { error in XCTAssertTrue(error.localizedDescription.contains("restoration failed")) }
    }

    func testOversizedTextRejectedBeforeClipboardAccess() {
        let board = MemoryClipboard()
        XCTAssertThrowsError(try ClipboardInput.transact(
            String(repeating: "x", count: 8 * 1024 * 1024 + 1),
            store: board,
            validateReceiver: {},
            sendPaste: { _, _ in XCTFail("must not send") }
        ))
        XCTAssertEqual(board.changeCount, 0)
    }
}
