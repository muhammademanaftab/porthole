import Foundation

public enum HTTPLimits {
    public static let maxConnections = 64
    public static let maxRequestBytes = 16384
    public static let requestSeconds: Double = 5
    public static let totalSeconds: Double = 60

    public enum Step: Equatable, Sendable { case more, ready, refuse }

    public static func step(_ received: Data, complete: Bool) -> Step {
        if received.range(of: Data("\r\n\r\n".utf8)) != nil { return .ready }
        if received.count >= maxRequestBytes || complete { return .refuse }
        return .more
    }
}
