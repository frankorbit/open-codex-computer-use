import AppKit
import Darwin
@testable import OpenComputerUseKit
import XCTest

final class SnapshotProcessIdentityTests: XCTestCase {
    func testKernelIdentityDoesNotRequireAppKitLaunchDate() throws {
        let value = try XCTUnwrap(SnapshotProcessIdentity.decode(info(), bytesRead: size, pid: 42))
        XCTAssertEqual(value, .init(pid: 42, startSeconds: 1000, startMicroseconds: 123))
    }

    func testPartialUnreadableMismatchedAndZombieProcessEvidenceIsRejected() {
        for count: Int32 in [-1, 0, size - 1] {
            XCTAssertNil(SnapshotProcessIdentity.decode(info(), bytesRead: count, pid: 42))
        }
        XCTAssertNil(SnapshotProcessIdentity.decode(info(), bytesRead: size, pid: 0))
        XCTAssertNil(SnapshotProcessIdentity.decode(info(), bytesRead: size, pid: 43))
        var invalid = info()
        invalid.pbi_start_tvsec = 0
        XCTAssertNil(SnapshotProcessIdentity.decode(invalid, bytesRead: size, pid: 42))
        invalid = info()
        invalid.pbi_start_tvusec = 1_000_000
        XCTAssertNil(SnapshotProcessIdentity.decode(invalid, bytesRead: size, pid: 42))
        invalid = info()
        invalid.pbi_status = UInt32(SZOMB)
        XCTAssertNil(SnapshotProcessIdentity.decode(invalid, bytesRead: size, pid: 42))
    }

    func testCaptureRequiresOriginalApplicationAliveBeforeAndAfterKernelRead() {
        var reads = 0
        let read: (pid_t) -> SnapshotProcessIdentity? = { pid in
            reads += 1
            return .init(pid: pid, startSeconds: 1000)
        }
        XCTAssertNil(SnapshotProcessIdentity.capture(pid: 42, isLiveOriginal: { false }, read: read))
        XCTAssertEqual(reads, 0)
        var checks = 0
        XCTAssertNil(SnapshotProcessIdentity.capture(pid: 42, isLiveOriginal: {
            checks += 1
            return checks == 1
        }, read: read))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(checks, 2)
        XCTAssertNil(SnapshotProcessIdentity.capture(pid: 42, isLiveOriginal: { true }, read: { _ in nil }))
        XCTAssertNil(SnapshotProcessIdentity.capture(pid: 42, isLiveOriginal: { true }, read: { _ in
            .init(pid: 43, startSeconds: 1000)
        }))
    }

    func testSamePidWithDifferentMicrosecondStartIsRejected() throws {
        let app = RunningAppDescriptor(name: "Fixture", bundleIdentifier: nil, pid: 42, runningApplication: .current)
        let original = SnapshotProcessIdentity(pid: 42, startSeconds: 1000, startMicroseconds: 123)
        let binding = SnapshotObservationBinding(app: app, processIdentity: original)
        XCTAssertNoThrow(try binding.validate(current: original))
        XCTAssertThrowsError(try binding.validate(current: .init(pid: 42, startSeconds: 1000, startMicroseconds: 124)))
    }

    func testDescriptorRetainsItsCapturedKernelIdentity() throws {
        var current: SnapshotProcessIdentity? = .init(pid: 42, startSeconds: 1000, startMicroseconds: 123)
        var reads = 0
        let descriptor = RunningAppDescriptor(name: "Fixture", bundleIdentifier: nil, pid: 42,
                                              runningApplication: .current, captureIdentity: { _, _ in
                                                  reads += 1
                                                  return current
                                              })
        let captured = try XCTUnwrap(descriptor.observedProcessIdentity)
        current = .init(pid: 42, startSeconds: 1000, startMicroseconds: 124)
        XCTAssertEqual(descriptor.observedProcessIdentity, captured)
        XCTAssertThrowsError(try SnapshotObservationBinding(app: descriptor, processIdentity: captured)
            .validate(current: current))
        XCTAssertEqual(reads, 1)
        // 合成的 AppKit 对象与 PID 不符时，即便有内核 token 也不能获得真实绑定。
        XCTAssertNil(SnapshotProcessIdentity.bound(to: descriptor))
    }

    func testFailedCaptureIsNotReplacedByLaterProcessEvidence() {
        var current: SnapshotProcessIdentity?
        var reads = 0
        let descriptor = RunningAppDescriptor(name: "Fixture", bundleIdentifier: nil, pid: 42,
                                              runningApplication: .current, captureIdentity: { _, _ in
                                                  reads += 1
                                                  return current
                                              })
        current = .init(pid: 42, startSeconds: 1000)
        XCTAssertNil(descriptor.observedProcessIdentity)
        XCTAssertEqual(reads, 1)
    }

    func testInitializationUsesCapturedKernelIdentityAndOpensOnlyOnce() throws {
        let app = fixtureDescriptor()
        var opens = 0
        var builds = 0
        let service = ComputerUseService(snapshotDependencies: dependencies(app: app, open: {
            opens += 1
        }, build: { builds += 1 }))
        XCTAssertFalse(try service.getAppState(app: "Fixture", initialize: true).isError)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(builds, 1)
    }

    func testIdentityFailureAfterOpenKeepsPendingInitializationWithoutReplaying() throws {
        let app = fixtureDescriptor()
        let original = try XCTUnwrap(app.observedProcessIdentity)
        for current: SnapshotProcessIdentity? in [
            nil,
            .init(pid: original.pid, startSeconds: original.startSeconds,
                  startMicroseconds: original.startMicroseconds + 1)
        ] {
            var opens = 0
            var builds = 0
            var deps = dependencies(app: app, open: { opens += 1 }, build: { builds += 1 })
            deps.processIdentity = { _ in current }
            let service = ComputerUseService(snapshotDependencies: deps)
            XCTAssertThrowsError(try service.getAppState(app: "Fixture", initialize: true)) { error in
                XCTAssertTrue(error.localizedDescription.contains("No further input was sent"))
            }
            XCTAssertThrowsError(try service.getAppState(app: "Fixture", initialize: true))
            XCTAssertEqual(opens, 1)
            XCTAssertEqual(builds, 0)
            XCTAssertThrowsError(try service.setValue(app: "Fixture", elementIndex: "1", value: "x"))
        }
    }

    func testMissingFrozenIdentityCannotBeReplacedDuringInitialization() {
        let app = RunningAppDescriptor(name: "Fixture", bundleIdentifier: "test.kernel-identity", pid: 42,
                                       runningApplication: .current, captureIdentity: { _, _ in nil })
        var opens = 0
        var builds = 0
        var deps = dependencies(app: app, open: { opens += 1 }, build: { builds += 1 })
        deps.processIdentity = { .init(pid: $0, startSeconds: 1000) }
        let service = ComputerUseService(snapshotDependencies: deps)
        XCTAssertThrowsError(try service.getAppState(app: "Fixture", initialize: true))
        XCTAssertThrowsError(try service.getAppState(app: "Fixture", initialize: true))
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(builds, 0)
    }

    func testRegisteredFinderProcessMetadataUsesProductionIdentityPath() throws {
        // 仅读取系统进程元数据；无桌面的 CI 不启动 Finder，也不发任何 GUI 输入。
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder is not running in this test environment")
        }
        let descriptor = RunningAppDescriptor(name: "Finder", bundleIdentifier: app.bundleIdentifier,
                                              pid: app.processIdentifier, runningApplication: app)
        let identity = try XCTUnwrap(SnapshotProcessIdentity.bound(to: descriptor))
        XCTAssertEqual(identity, SnapshotProcessIdentity.current(for: app.processIdentifier))
    }

    private func fixtureDescriptor() -> RunningAppDescriptor {
        RunningAppDescriptor(name: "Fixture", bundleIdentifier: "test.kernel-identity",
                             pid: 42, runningApplication: .current, captureIdentity: { _, pid in
                                 .init(pid: pid, startSeconds: 1000, startMicroseconds: 123)
                             })
    }

    private func dependencies(
        app: RunningAppDescriptor, open: @escaping () -> Void, build: @escaping () -> Void
    ) -> SnapshotDependencies {
        SnapshotDependencies(
            resolve: { _ in throw ComputerUseError.appNotFound("Fixture") },
            build: { _, _, _, policy, _ in
                XCTAssertEqual(policy, .readOnly)
                build()
                return AppSnapshot(app: app, windowTitle: "Fixture", windowBounds: nil, targetWindowID: 123,
                                   targetWindowLayer: 0, screenshotData: nil, mode: .accessibility, treeLines: [],
                                   focusedSummary: nil, focusedElement: nil, selectedText: nil, windowElement: nil,
                                   elements: [:])
            },
            processIdentity: { _ in app.observedProcessIdentity },
            bindingIdentity: { $0.observedProcessIdentity },
            prepareOpen: { _ in
                ApplicationOpeningRequest(identity: .bundle("test.kernel-identity"), perform: {
                    open()
                    return app
                })
            },
            openingWindowReady: { _, _ in true }
        )
    }

    private var size: Int32 {
        Int32(MemoryLayout<proc_bsdinfo>.stride)
    }

    private func info() -> proc_bsdinfo {
        var value = proc_bsdinfo()
        value.pbi_pid = 42
        value.pbi_status = UInt32(SRUN)
        value.pbi_start_tvsec = 1000
        value.pbi_start_tvusec = 123
        return value
    }
}
