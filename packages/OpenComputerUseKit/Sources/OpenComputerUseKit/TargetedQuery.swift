import Foundation

struct TargetedAppIdentity: Equatable {
    let pid: Int32
    let bundleIdentifier: String?
    let launchedAt: Date?

    init(app: RunningAppDescriptor) {
        pid = app.pid
        bundleIdentifier = app.bundleIdentifier
        launchedAt = app.runningApplication.launchDate
    }

    init(pid: Int32, bundleIdentifier: String?, launchedAt: Date?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.launchedAt = launchedAt
    }
}

/// Session-local handles. A cleared/evicted handle is never assigned again.
final class TargetedElementRegistry<Value> {
    static var indexBase: Int { 1_000_000 }
    private var nextIndex = indexBase
    private let capacity: Int
    private let lifetime: TimeInterval
    private let now: () -> Date
    private struct Entry {
        let app: TargetedAppIdentity
        let value: Value
        let expires: Date
    }
    private var entries: [Int: Entry] = [:]
    private var order: [Int] = []

    init(capacity: Int = 5000, lifetime: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
        self.now = now
    }

    func insert(app: TargetedAppIdentity, value: (Int) -> Value) -> Int {
        nextIndex += 1
        let index = nextIndex
        entries[index] = Entry(app: app, value: value(index), expires: now().addingTimeInterval(lifetime))
        order.append(index)
        if order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        return index
    }

    func resolve(_ index: Int, app: TargetedAppIdentity) throws -> Value {
        guard let entry = entries[index], now() < entry.expires else {
            entries.removeValue(forKey: index)
            throw ComputerUseError.stateUnavailable("Query index \(index) has expired or is no longer available; run query again in this session")
        }
        guard entry.app == app else {
            throw ComputerUseError.invalidArguments("Query index \(index) belongs to a different application process; run query for the requested app")
        }
        return entry.value
    }

    func remove(_ index: Int) { entries.removeValue(forKey: index) }
    func removeAll(forPIDs pids: Set<Int32>) {
        entries = entries.filter { !pids.contains($0.value.app.pid) }
        order.removeAll { entries[$0] == nil }
    }
    func clear() { entries.removeAll(); order.removeAll() }
}

struct TargetedWalkResult<Node> {
    var matches: [Node] = []
    var visitedNodes = 0
    /// Nodes (or their child lists) that could not be read and were skipped with their subtrees.
    var unreadableNodes = 0
    var walkStopReason: String?
    /// Why the result may be incomplete: the walk stopped early, or else it skipped unreadable nodes.
    var stopReason: String? { walkStopReason ?? (unreadableNodes > 0 ? "unreadable_nodes" : nil) }
    var truncated: Bool { stopReason != nil }
}

/// A bounded queue and child page keep wide AX containers within the node budget.
/// One unreadable node (slow or vanished element) skips only its own subtree; an unreadable root stops the walk.
/// Dependencies are injectable so budget/timeout/cycle behavior can be tested without a desktop.
func boundedTargetedWalk<Node: Hashable>(
    root: Node, maxNodes: Int, limit: Int,
    expired: () -> Bool,
    inspect: (Node) throws -> (matches: Bool, descend: Bool),
    children: (Node, Int) throws -> (nodes: [Node], truncated: Bool)
) throws -> TargetedWalkResult<Node> {
    var result = TargetedWalkResult<Node>()
    var queue = [root]
    var seen: Set<Node> = [root]
    var head = 0
    while head < queue.count {
        if expired() { result.walkStopReason = "timeout"; break }
        if result.visitedNodes >= maxNodes { result.walkStopReason = "max_nodes"; break }
        let node = queue[head]
        head += 1
        result.visitedNodes += 1
        let scan: (matches: Bool, descend: Bool)
        do { scan = try inspect(node) } catch {
            if node == root { result.walkStopReason = "ax_error"; break }
            result.unreadableNodes += 1
            continue
        }
        if expired() { result.walkStopReason = "timeout"; break }
        if scan.matches {
            result.matches.append(node)
            if result.matches.count >= limit { result.walkStopReason = "limit"; break }
        }
        if scan.descend {
            let remaining = max(0, maxNodes - seen.count)
            let page: (nodes: [Node], truncated: Bool)
            do { page = try children(node, remaining) } catch {
                if node == root { result.walkStopReason = "ax_error"; break }
                result.unreadableNodes += 1
                continue
            }
            if expired() { result.walkStopReason = "timeout"; break }
            if page.truncated || page.nodes.count > remaining { result.walkStopReason = "max_nodes" }
            for child in page.nodes.prefix(remaining) where seen.insert(child).inserted { queue.append(child) }
        }
    }
    return result
}
