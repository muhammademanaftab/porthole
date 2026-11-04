import Foundation

public struct SessionRegistry: Sendable {
    public enum OpenStep: Equatable, Sendable { case alreadyLive, waitForStart, start }

    public private(set) var viewers: [UInt32: Set<String>] = [:]
    public private(set) var live: Set<UInt32> = []
    public private(set) var starting: Set<UInt32> = []

    public init() {}

    public var openCount: Int { live.count }

    public var activeViewers: Set<String> {
        live.reduce(into: Set<String>()) { $0.formUnion(viewers[$1] ?? []) }
    }

    public mutating func beginOpen(_ id: UInt32, by who: String) -> OpenStep {
        viewers[id, default: []].insert(who)
        if live.contains(id) { return .alreadyLive }
        if starting.contains(id) { return .waitForStart }
        starting.insert(id)
        return .start
    }

    public mutating func startSucceeded(_ id: UInt32) -> Bool {
        starting.remove(id)
        guard viewers[id]?.isEmpty == false else { viewers[id] = nil; return false }
        live.insert(id)
        return true
    }

    public mutating func startFailed(_ id: UInt32) {
        starting.remove(id)
    }

    public mutating func openFailed(_ id: UInt32, by who: String) {
        viewers[id]?.remove(who)
    }

    public func shouldReply(_ id: UInt32, to who: String) -> Bool {
        viewers[id]?.contains(who) == true
    }

    public mutating func release(_ id: UInt32, by who: String) -> Bool {
        viewers[id]?.remove(who)
        guard viewers[id]?.isEmpty ?? true, live.contains(id) else { return false }
        live.remove(id)
        viewers[id] = nil
        return true
    }

    public mutating func releaseAll(by who: String) -> [UInt32] {
        viewers.keys.sorted().filter { release($0, by: who) }
    }

    public mutating func windowClosed(_ id: UInt32) -> Set<String>? {
        guard live.remove(id) != nil else { return nil }
        return viewers.removeValue(forKey: id) ?? []
    }

    public mutating func reset() -> [UInt32] {
        let ids = live.sorted()
        live.removeAll()
        viewers.removeAll()
        return ids
    }

    public func acceptsInput(_ id: UInt32, from who: String) -> Bool {
        live.contains(id) && viewers[id]?.contains(who) == true
    }
}

public struct StillStarting: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "The window is still starting. Try again in a moment." }
}

public final class StartGate<Key: Hashable & Sendable>: @unchecked Sendable {
    private var tasks: [Key: Task<Void, Error>] = [:]
    private let lock = NSLock()

    public init() {}

    public var keys: Set<Key> {
        lock.lock(); defer { lock.unlock() }
        return Set(tasks.keys)
    }

    @discardableResult
    public func begin(_ key: Key, _ work: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        let task = Task { try await work() }
        lock.lock(); tasks[key] = task; lock.unlock()
        return task
    }

    private func task(for key: Key) -> Task<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        return tasks[key]
    }

    public func wait(_ key: Key) async throws {
        guard let task = task(for: key) else { throw StillStarting() }
        try await task.value
    }

    public func finish(_ key: Key) {
        lock.lock(); tasks[key] = nil; lock.unlock()
    }
}
