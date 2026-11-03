public struct SharedUse<Key: Hashable & Sendable, User: Hashable & Sendable>: Sendable {
    public private(set) var owners: [User: Key] = [:]

    public init() {}

    public var keys: Set<Key> { Set(owners.values) }

    public func users(of key: Key) -> Set<User> {
        Set(owners.compactMap { $0.value == key ? $0.key : nil })
    }

    @discardableResult
    public mutating func add(_ user: User, to key: Key) -> Bool {
        let before = keys
        owners[user] = key
        return keys != before
    }

    @discardableResult
    public mutating func remove(_ user: User) -> Bool {
        let before = keys
        owners[user] = nil
        return keys != before
    }

    @discardableResult
    public mutating func removeAll() -> Bool {
        let had = !owners.isEmpty
        owners.removeAll()
        return had
    }
}

public enum AudioMixStep: Equatable, Sendable {
    case none
    case start(Set<Int32>)
    case update(Set<Int32>)
    case stop

    public static func next(running: Set<Int32>?, want: Set<Int32>) -> AudioMixStep {
        switch (running, want.isEmpty) {
        case (nil, true): return .none
        case (nil, false): return .start(want)
        case (.some, true): return .stop
        case (.some(let now), false): return now == want ? .none : .update(want)
        }
    }
}

public enum AudioFormat {
    public static let sampleRate = 48_000
    public static let channels = 2
    public static let maxBitrate = 96_000
}
