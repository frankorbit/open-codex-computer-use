import AppKit
@testable import OpenComputerUseKit
import XCTest

final class HoverPopupBudgetTests: XCTestCase {
    private typealias Observation = HoverPopupObservation
    private let root = Observation.Window(windowID: 10, pid: 123, bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
    private let popup = Observation.Window(
        windowID: 11,
        pid: 123,
        bounds: CGRect(x: 50, y: 50, width: 100, height: 100)
    )

    private func collector(budget: HoverPopupBudget) -> HoverPopupSystemCapture {
        HoverPopupSystemCapture(
            pid: root.pid, rootID: root.windowID, rootBounds: root.bounds, application: .current,
            budget: budget,
            settings: .init(config: .defaults, policy: .background, backgroundAvailable: true)
        )
    }

    private func image() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(encodeScreenshot(for: XCTUnwrap(context.makeImage()), config: .defaults).data)
    }

    private func drain(_ worker: HoverPopupCaptureWorker) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while worker.isCapturing, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(worker.isCapturing)
    }

    func testNoCGCandidateSkipsAXAndCaptureIncludingOtherAppWindows() {
        let other = Observation.Window(windowID: 12, pid: 456, bounds: popup.bounds)
        let result = collector(budget: .init(duration: 1)).capture(dependencies: .init(
            readWindows: { [other, self.root] },
            readAX: { XCTFail("No CG candidate must skip AX"); return nil },
            captureImage: { _ in XCTFail("No CG candidate must skip screenshots"); return nil }
        ))
        XCTAssertFalse(result.isIncomplete)
        XCTAssertTrue(result.popups.isEmpty)
    }

    func testCGCandidateStillRequiresAXExclusionBeforeScreenshot() {
        var reads = 0
        let result = collector(budget: .init(duration: 1)).capture(dependencies: .init(
            readWindows: { [self.popup, self.root] },
            readAX: {
                reads += 1
                return .init(windows: [], independentWindowIDs: [self.popup.windowID])
            },
            captureImage: { _ in XCTFail("Standard windows must remain excluded"); return nil }
        ))
        XCTAssertFalse(result.isIncomplete)
        XCTAssertTrue(result.popups.isEmpty)
        XCTAssertGreaterThan(reads, 0)
    }

    func testBlockedAXOrCaptureReturnsWithinBudgetAndDoesNotQueueMoreWorkers() throws {
        let data = try image()
        for blockAX in [true, false] {
            let release = DispatchSemaphore(value: 0)
            let entered = DispatchSemaphore(value: 0)
            let worker = HoverPopupCaptureWorker()
            let budget = HoverPopupBudget(duration: 0.08)
            let collector = collector(budget: budget)
            let start = ProcessInfo.processInfo.systemUptime
            let result = worker.capture(budget: budget) {
                collector.capture(dependencies: .init(
                    readWindows: { [self.popup, self.root] },
                    readAX: {
                        if blockAX { entered.signal(); release.wait() }
                        return .init(windows: [])
                    },
                    captureImage: { _ in
                        if !blockAX { entered.signal(); release.wait() }
                        return data
                    }
                ))
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            XCTAssertTrue(result.isIncomplete)
            XCTAssertTrue(result.popups.isEmpty)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.6)
            XCTAssertTrue(worker.isCapturing)
            for _ in 0 ..< 20 {
                let busy = worker.capture(budget: .init(duration: 1)) {
                    XCTFail("A blocked worker must not enqueue another capture")
                    return .init()
                }
                XCTAssertTrue(busy.isIncomplete)
                XCTAssertTrue(busy.popups.isEmpty)
            }
            release.signal()
            drain(worker)
            // 晚到图片没有缓存；下一次请求只取得自身新结果。
            let fresh = worker.capture(budget: .init(duration: 1)) { .init() }
            XCTAssertFalse(fresh.isIncomplete)
            XCTAssertTrue(fresh.popups.isEmpty)
        }
    }

    func testSharedDeadlineStopsBatchAfterSlowCaptureAndDiscardsEarlierImages() throws {
        let data = try image()
        let second = Observation.Window(windowID: 12, pid: root.pid, bounds: popup.bounds.offsetBy(dx: 100, dy: 0))
        let third = Observation.Window(windowID: 13, pid: root.pid, bounds: popup.bounds.offsetBy(dx: 200, dy: 0))
        var captures = 0
        let budget = HoverPopupBudget(duration: 0.06)
        let result = collector(budget: budget).capture(dependencies: .init(
            readWindows: { [self.popup, second, third, self.root] },
            readAX: { .init(windows: []) },
            captureImage: { _ in
                captures += 1
                if captures == 2 { Thread.sleep(forTimeInterval: 0.08) }
                return data
            }
        ))
        XCTAssertEqual(captures, 2)
        XCTAssertTrue(result.isIncomplete)
        XCTAssertTrue(result.popups.isEmpty)
    }

    func testSuccessfulBatchUsesExistingScopeAndProducesRealImageBeforeDeadline() throws {
        let data = try image()
        let worker = HoverPopupCaptureWorker()
        let budget = HoverPopupBudget(duration: 1)
        let collector = collector(budget: budget)
        let result = worker.capture(budget: budget) {
            collector.capture(dependencies: .init(
                readWindows: { [self.popup, self.root] },
                readAX: { .init(windows: []) }, captureImage: { _ in data }
            ))
        }
        XCTAssertFalse(result.isIncomplete)
        let observed = try XCTUnwrap(result.popups.first)
        XCTAssertEqual(observed.imageData, data)
        XCTAssertEqual(observed.windowID, popup.windowID)
        XCTAssertTrue(observed.permitsBackgroundInput)
        XCTAssertFalse(observed.permitsInput)
    }

    func testFrozenSettingsDoNotReadRestoredRequestEnvironment() {
        let key = "OPEN_COMPUTER_USE_EXECUTION_MODE"
        let old = ProcessInfo.processInfo.environment[key]
        defer { if let old { setenv(key, old, 1) } else { unsetenv(key) } }
        setenv(key, "background", 1)
        var config = ImageCaptureConfig.defaults
        config.format = "jpg"
        let settings = Observation.CaptureSettings(
            config: config, policy: try? ExecutionPolicy.current(), backgroundAvailable: true
        )
        let release = DispatchSemaphore(value: 0)
        let worker = HoverPopupCaptureWorker()
        let result = worker.capture(budget: .init(duration: 0.05)) {
            release.wait()
            XCTAssertTrue(settings.allowBackgroundInput)
            XCTAssertFalse(settings.allowInput)
            XCTAssertEqual(settings.config.format, "jpg")
            return .init()
        }
        XCTAssertTrue(result.isIncomplete)
        unsetenv(key)
        config.format = "png"
        release.signal()
        drain(worker)
    }

    func testModesHaveDistinctBoundedDurationsAndExpiredRequestDoesNotStart() {
        XCTAssertGreaterThan(HoverPopupObservationMode.explicit.duration, HoverPopupObservationMode.ordinary.duration)
        XCTAssertLessThanOrEqual(HoverPopupObservationMode.explicit.duration, 1)
        let worker = HoverPopupCaptureWorker()
        XCTAssertTrue(worker.capture(budget: .init(duration: 0)) {
            XCTFail("Expired request must not start a worker")
            return .init()
        }.isIncomplete)
        XCTAssertFalse(worker.isCapturing)
    }

    func testLateSuccessfulResultIsDiscardedAndNeverReusedByNextRequest() {
        let release = DispatchSemaphore(value: 0)
        let worker = HoverPopupCaptureWorker()
        let stale = Observation(
            token: UUID().uuidString, windowID: popup.windowID, pid: popup.pid, bounds: popup.bounds,
            imageData: Data([1]), pixelSize: CGSize(width: 10, height: 10)
        )
        let result = worker.capture(budget: .init(duration: 0.05)) {
            release.wait()
            // 模拟不遵守协作取消、仍成功返回旧图的系统调用。
            return .init(popups: [stale])
        }
        XCTAssertTrue(result.isIncomplete)
        XCTAssertTrue(result.popups.isEmpty)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            XCTAssertTrue(worker.capture(budget: .init(duration: 1)) {
                XCTFail("Concurrent requests must not start another worker")
                return .init()
            }.isIncomplete)
        }
        release.signal()
        drain(worker)
        let next = worker.capture(budget: .init(duration: 1)) { .init() }
        XCTAssertFalse(next.isIncomplete)
        XCTAssertTrue(next.popups.isEmpty)
    }
}
