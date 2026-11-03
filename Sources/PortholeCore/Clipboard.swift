public let clipboardTopic = "porthole-clip"

public struct ClipboardSync: Sendable {
    public static let maxBytes = 1_000_000

    private var seenChange: Int
    private var lastText: String?

    public init(changeCount: Int) { seenChange = changeCount }

    public mutating func outgoing(changeCount: Int, text: () -> String?) -> String? {
        guard changeCount != seenChange else { return nil }
        seenChange = changeCount
        guard let t = text(), Self.fits(t), t != lastText else { return nil }
        lastText = t
        return t
    }

    public mutating func incoming(_ text: String) -> Bool {
        guard Self.fits(text), text != lastText else { return false }
        lastText = text
        return true
    }

    public mutating func applied(changeCount: Int) { seenChange = changeCount }

    public static func fits(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= maxBytes }
}
