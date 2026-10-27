import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXSidebarSelectionTests: XCTestCase {
    private final class Node {
        let role: String
        let identifier: String?
        let parent: Node?

        init(_ role: String, identifier: String? = nil, parent: Node? = nil) {
            self.role = role
            self.identifier = identifier
            self.parent = parent
        }
    }

    private final class Harness {
        let outline = Node("AXOutline", identifier: "sidebar")
        lazy var row = Node("AXRow", parent: outline)
        var capabilities: [(Node, String)] = []
        var prepared: [Node] = []
        var submissions: [(Node, [Node])] = []
        var rowCapability: (AXError, Bool) = (.success, true)
        var outlineCapability: (AXError, Bool) = (.success, true)
        var setterResult: AXError = .success

        var reader: AXSidebarSelectionReader<Node> {
            .init(
                parent: { $0.parent },
                role: { $0.role },
                isSidebar: { $0.identifier == "sidebar" },
                selectionCapability: { element, attribute in
                    self.capabilities.append((element, attribute))
                    return element === self.row ? self.rowCapability : self.outlineCapability
                }
            )
        }

        func run(
            target: Node? = nil,
            bundleIdentifier: String? = "com.apple.finder",
            reader: AXSidebarSelectionReader<Node>? = nil,
            prepare: ((Node) throws -> Void)? = nil
        ) throws -> Bool {
            try selectFinderSidebarRow(
                target ?? row, bundleIdentifier: bundleIdentifier, reader: reader ?? self.reader,
                prepare: { element in
                    self.prepared.append(element)
                    try prepare?(element)
                },
                select: { outline, rows in
                    self.submissions.append((outline, rows))
                    return self.setterResult
                }
            )
        }
    }

    private let failures: [AXError] = [
        .failure, .illegalArgument, .invalidUIElement, .invalidUIElementObserver, .cannotComplete,
        .attributeUnsupported, .actionUnsupported, .notificationUnsupported, .notImplemented,
        .notificationAlreadyRegistered, .notificationNotRegistered, .apiDisabled, .noValue,
        .parameterizedAttributeUnsupported, .notEnoughPrecision
    ]

    func testSelectsOnlyOriginalRowOnceAfterBothCapabilityChecks() throws {
        let harness = Harness()
        XCTAssertTrue(try harness.run(prepare: { outline in
            XCTAssertTrue(outline === harness.outline)
            XCTAssertEqual(harness.capabilities.count, 2)
            XCTAssertTrue(harness.submissions.isEmpty)
        }))
        XCTAssertEqual(harness.capabilities.map(\.1), ["AXSelected", "AXSelectedRows"])
        XCTAssertTrue(harness.capabilities[0].0 === harness.row)
        XCTAssertTrue(harness.capabilities[1].0 === harness.outline)
        XCTAssertEqual(harness.prepared.count, 1)
        XCTAssertEqual(harness.submissions.count, 1)
        let submission = try XCTUnwrap(harness.submissions.first)
        XCTAssertTrue(submission.0 === harness.outline)
        XCTAssertEqual(submission.1.count, 1)
        XCTAssertTrue(submission.1.first === harness.row)
    }

    func testEverySetterFailureStopsWithoutFurtherRouteOrReplay() {
        for error in failures {
            let harness = Harness()
            harness.setterResult = error
            var subsequentOperations = 0
            XCTAssertThrowsError(try {
                _ = try harness.run()
                subsequentOperations += 1
            }()) { thrown in
                XCTAssertTrue(thrown.localizedDescription.contains("failed with \(error.rawValue)"))
                XCTAssertTrue(thrown.localizedDescription.contains("selection was attempted"))
                XCTAssertTrue(thrown.localizedDescription.contains("do not replay"))
            }
            XCTAssertEqual(harness.prepared.count, 1)
            XCTAssertEqual(harness.submissions.count, 1)
            XCTAssertEqual(subsequentOperations, 0)
        }
    }

    func testRowCapabilityErrorsStopBeforeOutlineQueryOrInput() {
        for error in failures where error != .attributeUnsupported {
            let harness = Harness()
            harness.rowCapability = (error, true)
            XCTAssertThrowsError(try harness.run()) { thrown in
                XCTAssertTrue(thrown.localizedDescription.contains("AX \(error.rawValue)"))
            }
            XCTAssertEqual(harness.capabilities.count, 1)
            XCTAssertTrue(harness.prepared.isEmpty)
            XCTAssertTrue(harness.submissions.isEmpty)
        }
    }

    func testHeaderOrUnsupportedRowKeepsExistingPathWithoutInput() throws {
        for capability: (AXError, Bool) in [(.success, false), (.attributeUnsupported, false)] {
            let harness = Harness()
            harness.rowCapability = capability
            XCTAssertFalse(try harness.run())
            XCTAssertEqual(harness.capabilities.count, 1)
            XCTAssertTrue(harness.prepared.isEmpty)
            XCTAssertTrue(harness.submissions.isEmpty)
        }
    }

    func testOutlineCapabilityFailuresStopBeforeInput() {
        for capability in failures.map({ ($0, true) }) + [(.success, false)] {
            let harness = Harness()
            harness.outlineCapability = capability
            XCTAssertThrowsError(try harness.run()) { thrown in
                if capability.0 == .apiDisabled {
                    XCTAssertTrue(thrown.localizedDescription.hasPrefix("Accessibility permission is required"))
                } else {
                    XCTAssertTrue(thrown.localizedDescription.contains("AXSelectedRows is unavailable"))
                }
            }
            XCTAssertEqual(harness.capabilities.count, 2)
            XCTAssertTrue(harness.prepared.isEmpty)
            XCTAssertTrue(harness.submissions.isEmpty)
        }
    }

    func testNonFinderDoesNotReadAccessibilityMetadata() throws {
        for bundleIdentifier in [nil, "com.apple.TextEdit", "com.apple.finder.extra", "com.apple.Finder"] {
            let harness = Harness()
            let reader = AXSidebarSelectionReader<Node>(
                parent: { _ in XCTFail("非 Finder 不应读取父节点"); return nil },
                role: { _ in XCTFail("非 Finder 不应读取角色"); return nil },
                isSidebar: { _ in XCTFail("非 Finder 不应读取标识"); return false },
                selectionCapability: { _, _ in XCTFail("非 Finder 不应查询能力"); return (.success, true) }
            )
            XCTAssertFalse(try harness.run(bundleIdentifier: bundleIdentifier, reader: reader))
            XCTAssertTrue(harness.prepared.isEmpty)
            XCTAssertTrue(harness.submissions.isEmpty)
        }
    }

    func testOnlyExactRowAndDirectSidebarOutlineMatch() throws {
        let harness = Harness()
        let targets = [
            Node("AXStaticText", parent: harness.row),
            Node("AXTextField", parent: harness.row),
            Node("AXButton", parent: harness.row),
            Node("AXDisclosureTriangle", parent: harness.row),
            Node("AXCheckBox", parent: harness.row),
            Node("AXRow"),
            Node("AXRow", parent: Node("AXGroup", parent: harness.outline)),
            Node("AXRow", parent: Node("AXTable", identifier: "sidebar")),
            Node("AXRow", parent: Node("AXList", identifier: "sidebar")),
            Node("AXRow", parent: Node("AXWebArea", identifier: "sidebar")),
            Node("AXRow", parent: Node("AXOutline")),
            Node("AXRow", parent: Node("AXOutline", identifier: "Sidebar")),
            Node("AXRow", parent: Node("AXOutline", identifier: "contents")),
            harness.outline
        ]
        for target in targets {
            XCTAssertFalse(try harness.run(target: target))
        }
        XCTAssertTrue(harness.capabilities.isEmpty)
        XCTAssertTrue(harness.prepared.isEmpty)
        XCTAssertTrue(harness.submissions.isEmpty)
    }

    func testMetadataReadFailuresPropagateWithoutInput() {
        for failedRead in ["rowRole", "parent", "outlineRole", "identifier"] {
            let harness = Harness()
            let rejection = ComputerUseError.stateUnavailable("AX metadata \(failedRead): stale or denied")
            let reader = AXSidebarSelectionReader<Node>(
                parent: { element in
                    if failedRead == "parent" { throw rejection }
                    return element.parent
                },
                role: { element in
                    if failedRead == (element === harness.row ? "rowRole" : "outlineRole") { throw rejection }
                    return element.role
                },
                isSidebar: { element in
                    if failedRead == "identifier" { throw rejection }
                    return element.identifier == "sidebar"
                },
                selectionCapability: { _, _ in
                    XCTFail("元数据读取失败后不应继续查询能力")
                    return (.success, true)
                }
            )
            XCTAssertThrowsError(try harness.run(reader: reader)) { thrown in
                XCTAssertEqual(thrown.localizedDescription, rejection.localizedDescription)
            }
            XCTAssertTrue(harness.prepared.isEmpty)
            XCTAssertTrue(harness.submissions.isEmpty)
        }
    }

    func testPreparationRejectionStopsBeforeSetter() {
        let harness = Harness()
        let rejection = ComputerUseError.stateUnavailable("Sidebar row became stale before input")
        XCTAssertThrowsError(try harness.run(prepare: { _ in throw rejection })) { thrown in
            XCTAssertEqual(thrown.localizedDescription, rejection.localizedDescription)
        }
        XCTAssertEqual(harness.prepared.count, 1)
        XCTAssertTrue(harness.submissions.isEmpty)
    }
}

extension AXSidebarSelectionTests {
    func testDisabledAccessibilityCapabilityRemainsPermissionDenied() {
        for isRow in [true, false] {
            for settable in [true, false] {
                let harness = Harness()
                if isRow {
                    harness.rowCapability = (.apiDisabled, settable)
                } else {
                    harness.outlineCapability = (.apiDisabled, settable)
                }
                XCTAssertThrowsError(try harness.run()) { thrown in
                    guard case let ComputerUseError.permissionDenied(message) = thrown else {
                        return XCTFail("权限拒绝不能变成状态不可用或成功")
                    }
                    XCTAssertTrue(message.hasPrefix("Accessibility permission is required"))
                    XCTAssertTrue(message.contains("AX \(AXError.apiDisabled.rawValue)"))
                    XCTAssertTrue(message.contains("do not replay"))
                }
                XCTAssertEqual(harness.capabilities.count, isRow ? 1 : 2)
                XCTAssertTrue(harness.prepared.isEmpty)
                XCTAssertTrue(harness.submissions.isEmpty)
            }
        }
    }

    func testCapabilityDeadlineCancellationAndPermissionErrorsPropagateBeforeInput() {
        let rejections: [Error] = [
            ComputerUseError.stateUnavailable("AX_INPUT_PREFLIGHT: original deadline exceeded"),
            CancellationError(),
            ComputerUseError.permissionDenied("original permission rejection")
        ]
        for attribute in ["AXSelected", "AXSelectedRows"] {
            for afterRead in [false, true] {
                for rejection in rejections {
                    let harness = Harness()
                    var queried: [String] = []
                    var completedReads: [String] = []
                    let reader = AXSidebarSelectionReader<Node>(
                        parent: { $0.parent }, role: { $0.role }, isSidebar: { $0.identifier == "sidebar" },
                        selectionCapability: { _, currentAttribute in
                            queried.append(currentAttribute)
                            if currentAttribute == attribute, !afterRead { throw rejection }
                            completedReads.append(currentAttribute)
                            if currentAttribute == attribute { throw rejection }
                            return (.success, true)
                        }
                    )
                    XCTAssertThrowsError(try harness.run(reader: reader)) { thrown in
                        switch rejection {
                        case let ComputerUseError.stateUnavailable(message):
                            guard case let ComputerUseError.stateUnavailable(actual) = thrown else {
                                return XCTFail("deadline 错误必须原样传播")
                            }
                            XCTAssertEqual(actual, message)
                        case let ComputerUseError.permissionDenied(message):
                            guard case let ComputerUseError.permissionDenied(actual) = thrown else {
                                return XCTFail("权限错误必须原样传播")
                            }
                            XCTAssertEqual(actual, message)
                        default:
                            XCTAssertTrue(thrown is CancellationError)
                        }
                    }
                    let expectedQueries = attribute == "AXSelected" ? ["AXSelected"] : ["AXSelected", "AXSelectedRows"]
                    XCTAssertEqual(queried, expectedQueries)
                    XCTAssertEqual(completedReads, afterRead ? expectedQueries : Array(expectedQueries.dropLast()))
                    XCTAssertTrue(harness.prepared.isEmpty)
                    XCTAssertTrue(harness.submissions.isEmpty)
                }
            }
        }
    }
}
