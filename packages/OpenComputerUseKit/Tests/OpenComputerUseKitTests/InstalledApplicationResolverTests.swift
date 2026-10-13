import AppKit
@testable import OpenComputerUseKit
import XCTest

final class InstalledApplicationResolverTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testFileBaseAndEveryLocalizedNameResolveToOneIdentity() throws {
        let app = try makeApp("MusicPlayer", identifier: "test.music", name: "Music Core", displayName: "Music Player")
        try localization(app, language: "en", values: ["CFBundleDisplayName": "Cloud Music"])
        try localization(app, language: "zh-Hans", values: ["CFBundleName": "云端音乐"], format: .binary)
        try localization(app, language: "ja", values: ["CFBundleDisplayName": "音楽プレーヤー"])
        for query in [
            "MusicPlayer",
            "  musicplayer.APP  ",
            "Music Core",
            "Music Player",
            "Cloud Music",
            "云端音乐",
            "音楽プレーヤー"
        ] {
            XCTAssertEqual(try resolve(query), app)
        }
    }

    func testStringsTextUTF16AndUnicodeNormalization() throws {
        let app = try makeApp("Cafe", identifier: "test.cafe")
        let directory = app.appendingPathComponent("Contents/Resources/fr.lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let strings = "\"CFBundleDisplayName\" = \"Café\";"
        try XCTUnwrap(strings.data(using: .utf16)).write(to: directory.appendingPathComponent("InfoPlist.strings"))
        XCTAssertEqual(try resolve("CAFE\u{301}"), app)
        XCTAssertNil(try resolve("Caf"))
    }

    func testMalformedOrMissingLocalizationKeepsBaseNames() throws {
        let app = try makeApp("Editor", identifier: "test.editor", name: "编辑器")
        let directory = app.appendingPathComponent("Contents/Resources/zh-Hans.lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x11]).write(to: directory.appendingPathComponent("InfoPlist.strings"))
        XCTAssertEqual(try resolve("Editor"), app)
        XCTAssertEqual(try resolve("编辑器"), app)
        XCTAssertNil(try resolve(""))
        XCTAssertNil(try resolve("missing"))
    }

    func testLocalizedTableNamesAndStringsAreBothSupported() throws {
        let app = try makeApp("Calculator", identifier: "test.calculator")
        try localization(app, language: "fr", values: ["CFBundleDisplayName": "Calculatrice"])
        let table: [String: Any] = [
            "zh_CN": ["CFBundleDisplayName": "计算器", "UnrelatedKey": "不能作为名称"],
            "de": ["CFBundleName": "Rechner"],
            "invalid": "忽略非字典值"
        ]
        let url = app.appendingPathComponent("Contents/Resources/InfoPlist.loctable")
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0).write(to: url)
        for name in ["Calculator", "计算器", "Rechner", "Calculatrice"] {
            XCTAssertEqual(try resolve(name), app)
        }
        XCTAssertNil(try resolve("不能作为名称"))
        try Data([0xFF, 0x11]).write(to: url)
        XCTAssertEqual(try resolve("Calculator"), app)
        XCTAssertEqual(try resolve("Calculatrice"), app)
    }

    func testDifferentAppsWithSameLocalizedNameRequireExplicitTarget() throws {
        let first = try makeApp("First", identifier: "test.first", displayName: "编辑器")
        let second = try makeApp("Second", identifier: "test.second", displayName: "编辑器")
        XCTAssertThrowsError(try resolve("编辑器")) { error in
            guard case let ComputerUseError.invalidArguments(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("test.first") && message.contains("test.second"))
            XCTAssertTrue(message.contains("absolute .app path"))
        }
        XCTAssertEqual(try AppDiscovery.installedApplicationURL(first.path), first)
        XCTAssertEqual(try AppDiscovery.installedApplicationURL(second.path), second)
    }

    func testSameIdentifierAtDifferentPathsStillRequiresDisambiguation() throws {
        _ = try makeApp("One", identifier: "test.copy", displayName: "Shared")
        _ = try makeApp("Two", identifier: "test.copy", displayName: "Shared")
        XCTAssertThrowsError(try resolve("Shared"))
    }

    func testRepeatedRootsAndSymlinkDoNotCreateFalseAmbiguity() throws {
        let app = try makeApp("Player", identifier: "test.player", displayName: "播放器")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.app"),
                                                   withDestinationURL: app)
        XCTAssertEqual(try InstalledApplicationResolver.applicationURL(named: "播放器", roots: [root, root]), app)
        XCTAssertEqual(try resolve("Alias"), app)
    }

    func testNestedHelperIsNotDiscoverableButAppsInSubfoldersAre() throws {
        let parent = try makeApp("Main", identifier: "test.main")
        _ = try makeApp("Helper", identifier: "test.helper", displayName: "内部工具",
                        directory: parent.appendingPathComponent("Contents/Helpers"))
        let utility = try makeApp("Utility", identifier: "test.utility", displayName: "用户工具",
                                  directory: root.appendingPathComponent("Utilities"))
        XCTAssertNil(try resolve("内部工具"))
        XCTAssertEqual(try resolve("用户工具"), utility)
    }

    func testDottedDisplayNameIsStillAName() throws {
        let app = try makeApp("Dotted", identifier: "test.dotted", displayName: "Example.Editor")
        XCTAssertEqual(try resolve("Example.Editor"), app)
    }

    func testReadOnlyLocalizedResolutionUsesRunningIdentityAndNeverLaunches() throws {
        let app = try makeApp("Player", identifier: "test.player", displayName: "播放器")
        let running = RunningAppDescriptor(name: "Player", bundleIdentifier: "test.player", pid: 41002,
                                           runningApplication: .current)
        let found = try AppDiscovery.resolve("播放器", in: [running], installedBundleIdentifier: { query in
            try self.resolve(query).flatMap { Bundle(url: $0)?.bundleIdentifier }
        })
        XCTAssertEqual(found.pid, running.pid)
        XCTAssertThrowsError(try AppDiscovery.resolve("播放器", in: [], installedBundleIdentifier: { _ in
            Bundle(url: app)?.bundleIdentifier
        })) { error in
            guard case ComputerUseError.appNotFound = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAmbiguityPropagatesWithoutOpeningOrChangingToNotFound() throws {
        _ = try makeApp("One", identifier: "test.one", displayName: "同名")
        _ = try makeApp("Two", identifier: "test.two", displayName: "同名")
        var launches = 0
        XCTAssertThrowsError(try AppDiscovery.open("同名", running: [], locate: resolve, launch: { _ in
            launches += 1
            throw ComputerUseError.message("Must not launch")
        }))
        XCTAssertEqual(launches, 0)
        XCTAssertThrowsError(try AppDiscovery.resolve("同名", in: [], installedBundleIdentifier: { query in
            try self.resolve(query).flatMap { Bundle(url: $0)?.bundleIdentifier }
        })) { error in
            guard case ComputerUseError.invalidArguments = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLocalizedOpenPreparesStableIdentityAndLaunchesExactlyOnce() throws {
        let app = try makeApp("Player", identifier: "test.player", displayName: "播放器")
        var launches = 0
        let request = try AppDiscovery.prepareOpen("播放器", running: [], locate: resolve, launch: { url in
            XCTAssertEqual(url, app)
            launches += 1
            return RunningAppDescriptor(name: "Player", bundleIdentifier: "test.player", pid: 41002,
                                        runningApplication: .current)
        })
        XCTAssertEqual(request.identity, .bundle("test.player"))
        XCTAssertEqual(launches, 0)
        _ = try request.perform()
        XCTAssertEqual(launches, 1)
    }

    func testRunningCandidateSubsetDoesNotScanOtherInstalledApplications() throws {
        let app = try makeApp("Running", identifier: "test.running", displayName: "播放器")
        let other = try makeApp("Stopped", identifier: "test.stopped", displayName: "播放器")
        XCTAssertEqual(try InstalledApplicationResolver.applicationURL(named: "播放器", applicationURLs: [app]), app)
        for urls in [[app, other], [other, app]] {
            XCTAssertThrowsError(try InstalledApplicationResolver.applicationURL(named: "播放器", applicationURLs: urls))
        }
    }

    func testLocalizedAliasCannotBypassExistingSafetyPolicy() throws {
        _ = try makeApp("PasswordApp", identifier: "com.bitwarden.desktop", displayName: "密码保管")
        var launches = 0
        XCTAssertThrowsError(try AppDiscovery.open("密码保管", running: [], locate: resolve, launch: { _ in
            launches += 1
            throw ComputerUseError.message("Must not launch")
        })) { error in
            guard case ComputerUseError.permissionDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(launches, 0)
        XCTAssertThrowsError(try AppDiscovery.resolve("密码保管", in: [], installedBundleIdentifier: { query in
            try self.resolve(query).flatMap { Bundle(url: $0)?.bundleIdentifier }
        })) { error in
            guard case ComputerUseError.permissionDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRealInstalledApplicationWhenExplicitlyEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let query = environment["OCU_DISCOVERY_PROBE_QUERY"],
              let identifier = environment["OCU_DISCOVERY_PROBE_IDENTIFIER"] else {
            throw XCTSkip("Explicit read-only installed-app probe is disabled")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let url = try XCTUnwrap(AppDiscovery.installedApplicationURL(query))
        XCTAssertEqual(Bundle(url: url)?.bundleIdentifier, identifier)
        print("installed_app_resolution_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
        let running = AppDiscovery.runningApps()
        if running.contains(where: { $0.bundleIdentifier == identifier }) {
            let match = try AppDiscovery.resolve(query, in: running, installedBundleIdentifier: { _ in
                XCTFail("运行中应用的本地化名称不应回退到全盘安装扫描")
                return nil
            })
            XCTAssertEqual(match.bundleIdentifier, identifier)
        }
    }

    private func resolve(_ query: String) throws -> URL? {
        try InstalledApplicationResolver.applicationURL(named: query, roots: [root])
    }

    private func makeApp(_ fileName: String, identifier: String, name: String? = nil,
                         displayName: String? = nil, directory: URL? = nil) throws -> URL {
        let app = (directory ?? root).appendingPathComponent(fileName + ".app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleName": name ?? fileName]
        if let displayName { info["CFBundleDisplayName"] = displayName }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app.resolvingSymlinksInPath()
    }

    private func localization(_ app: URL, language: String, values: [String: String],
                              format: PropertyListSerialization.PropertyListFormat = .xml) throws {
        let directory = app.appendingPathComponent("Contents/Resources/\(language).lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0)
            .write(to: directory.appendingPathComponent("InfoPlist.strings"))
    }
}
