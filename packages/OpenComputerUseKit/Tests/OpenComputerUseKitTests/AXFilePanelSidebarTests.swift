import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXFilePanelSidebarTests: XCTestCase {
    private final class Node {
        var role: String
        var identifier: String?
        var pid: pid_t = 123
        var visible: Bool? = true
        weak var parent: Node?
        var children: [Node] = []

        init(_ role: String, identifier: String? = nil, parent: Node? = nil) {
            self.role = role
            self.identifier = identifier
            self.parent = parent
            parent?.children.append(self)
        }
    }

    private final class Harness {
        let window = Node("AXWindow")
        lazy var panel = Node("AXSheet", identifier: "save-panel", parent: window)
        lazy var outline = Node("AXOutline", identifier: "sidebar", parent: panel)
        lazy var row = Node("AXRow", parent: outline)
        var readFailure: Error?
        var expired = false
        var setters = 0

        var reader: AXInputScopeReader<Node> {
            .init(role: { $0.role }, owner: { $0.pid }, parent: { $0.parent }, children: {
                if let failure = self.readFailure { throw failure }
                return $0.children
            }, visible: { $0.visible }, equal: { $0 === $1 }, checkDeadline: {
                if self.expired { throw axInputPreflightFailure("test deadline") }
            })
        }

        func run(boundWindow: Node? = nil) throws {
            try validateAXFilePanelSidebar(
                .init(row: row, outline: outline, panel: panel, window: boundWindow ?? window),
                pid: 123, reader: reader, identifier: { $0.identifier }
            )
            setters += 1
        }
    }

    func testOpenWindowAndAttachedSaveSheetAreAccepted() throws {
        let save = Harness()
        try save.run()
        XCTAssertEqual(save.setters, 1)
        let open = Harness()
        open.panel.role = "AXWindow"
        open.panel.identifier = "open-panel"
        try open.run(boundWindow: open.panel)
        XCTAssertEqual(open.setters, 1)
    }

    func testOnlyExactSystemPanelRolesAndIdentifiersMatch() {
        for role in [nil, "AXGroup", "AXWebArea", "AXWindow", "AXSheet"] {
            for identifier in [nil, "sidebar", "Save", "save-panel", "open-panel"] {
                XCTAssertEqual(isNativeFilePanel(role: role, identifier: identifier),
                               ["AXWindow", "AXSheet"].contains(role ?? "")
                                   && ["save-panel", "open-panel"].contains(identifier ?? ""))
            }
        }
    }

    func testStaleForeignDetachedAndReparentedTargetsNeverWrite() {
        let mutations: [(Harness) -> Void] = [
            { $0.panel.identifier = "document" },
            { $0.panel.visible = false },
            { $0.row.pid = 456 },
            { $0.panel.pid = 456 },
            { $0.row.parent = $0.window },
            { $0.outline.children = [] },
            { $0.window.children = [] },
            { $0.panel.parent = $0.outline },
            { $0.row.visible = false },
            { $0.outline.visible = false },
            { $0.row.role = "AXCell" }
        ]
        for mutation in mutations {
            let harness = Harness()
            _ = harness.row
            mutation(harness)
            XCTAssertThrowsError(try harness.run())
            XCTAssertEqual(harness.setters, 0)
        }
        let foreign = Harness()
        let anotherWindow = Node("AXWindow")
        XCTAssertThrowsError(try foreign.run(boundWindow: anotherWindow))
        XCTAssertEqual(foreign.setters, 0)
        let web = Harness()
        _ = web.row
        let webArea = Node("AXWebArea", parent: web.panel)
        web.outline.parent = webArea
        webArea.children = [web.outline]
        XCTAssertThrowsError(try web.run())
        XCTAssertEqual(web.setters, 0)
    }

    func testUnknownVisibilityStillRequiresAttachmentAndErrorsPropagate() throws {
        let unknown = Harness()
        unknown.panel.visible = nil
        try unknown.run()
        XCTAssertEqual(unknown.setters, 1)
        let expired = Harness()
        expired.expired = true
        XCTAssertThrowsError(try expired.run())
        XCTAssertEqual(expired.setters, 0)
        let errors: [Error] = [CancellationError(), ComputerUseError.permissionDenied("permission"),
                               ComputerUseError.stateUnavailable("read failed")]
        for error in errors {
            let harness = Harness()
            harness.readFailure = error
            XCTAssertThrowsError(try harness.run()) { thrown in
                XCTAssertEqual(String(describing: thrown), String(describing: error))
            }
            XCTAssertEqual(harness.setters, 0)
        }
    }
}
