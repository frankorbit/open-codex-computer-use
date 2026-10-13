import Foundation

/// 只读取安装包声明的名称，不翻译、模糊猜测或启动应用。
enum InstalledApplicationResolver {
    struct Candidate {
        let url: URL
        let bundleIdentifier: String
        let names: Set<String>
    }

    static func applicationURL(named query: String, roots: [URL]) throws -> URL? {
        guard !normalizedName(query).isEmpty else { return nil }
        let manager = FileManager.default
        var urls: [URL] = []
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                // 自定义或损坏包也不能递归发现其内部 helper。
                enumerator.skipDescendants()
                urls.append(url)
            }
        }
        return try applicationURL(named: query, applicationURLs: urls)
    }

    static func applicationURL(named query: String, applicationURLs: [URL]) throws -> URL? {
        let name = normalizedName(query)
        guard !name.isEmpty else { return nil }
        // 同一包的符号链接只计一个候选，同时保留链接自身的文件名。
        var fileNamesByURL: [URL: Set<String>] = [:]
        for url in applicationURLs {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            fileNamesByURL[canonical, default: []].insert(normalizedName(url.lastPathComponent))
        }
        let matches = fileNamesByURL.compactMap { url, fileNames -> Candidate? in
            guard let candidate = candidate(at: url),
                  candidate.names.contains(name) || fileNames.contains(name) else { return nil }
            return candidate
        }
        guard matches.count <= 1 else {
            let choices = matches.sorted { $0.url.path < $1.url.path }
                .map { "\($0.bundleIdentifier) (\($0.url.path))" }.joined(separator: "; ")
            throw ComputerUseError.invalidArguments(
                "Ambiguous application name '\(query)'. Use a bundle identifier or absolute .app path. "
                    + "Candidates: \(choices)"
            )
        }
        return matches.first?.url
    }

    static func candidate(at url: URL) -> Candidate? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            return nil
        }
        var names: Set<String> = [normalizedName(url.lastPathComponent)]
        func addNames(_ dictionary: [String: Any]?) {
            for key in ["CFBundleName", "CFBundleDisplayName"] {
                if let value = dictionary?[key] as? String {
                    let name = normalizedName(value)
                    if !name.isEmpty { names.insert(name) }
                }
            }
        }
        addNames(bundle.infoDictionary)
        // 显式读全部本地化资源，不受系统语言或 helper 进程的首选语言影响。
        if let resources = bundle.resourceURL {
            // 系统应用也可能把所有语言放在按语言分组的 loctable 中。
            if let table = propertyList(at: resources.appendingPathComponent("InfoPlist.loctable")) {
                for case let dictionary as [String: Any] in table.values {
                    addNames(dictionary)
                }
            }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: resources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where entry.pathExtension.caseInsensitiveCompare("lproj") == .orderedSame {
                addNames(propertyList(at: entry.appendingPathComponent("InfoPlist.strings")))
            }
        }
        return Candidate(url: url, bundleIdentifier: identifier, names: names)
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func normalizedName(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasSuffix(".app") { result.removeLast(4) }
        return result.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
