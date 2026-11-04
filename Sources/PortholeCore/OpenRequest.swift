import Foundation

public struct OpenRequest: Equatable, Sendable {
    public static let notification = "io.github.muhammademanaftab.porthole.open"
    public static let replyNotification = "io.github.muhammademanaftab.porthole.open.reply"

    public var address: String
    public var windowID: UInt32
    public var token: String

    public init(address: String, windowID: UInt32, token: String) {
        self.address = address; self.windowID = windowID; self.token = token
    }

    public var match: String { "id:\(windowID)" }

    public var userInfo: [String: String] { ["address": address, "window": String(windowID), "token": token] }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let address = userInfo?["address"] as? String, !address.isEmpty,
              let raw = userInfo?["window"] as? String, let id = UInt32(raw),
              let token = userInfo?["token"] as? String, !token.isEmpty else { return nil }
        self.init(address: address, windowID: id, token: token)
    }

    public enum Plan: Equatable, Sendable {
        case refreshList
        case connect
        case noCredential
    }

    public func plan(connectedTo host: String?, hasCredential: Bool) -> Plan {
        if host == address { return .refreshList }
        return hasCredential ? .connect : .noCredential
    }
}

public struct OpenReply: Equatable, Sendable {
    public var token: String
    public var ok: Bool
    public var message: String

    public init(token: String, ok: Bool, message: String) { self.token = token; self.ok = ok; self.message = message }

    public var userInfo: [String: String] { ["token": token, "ok": ok ? "1" : "0", "message": message] }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let token = userInfo?["token"] as? String, !token.isEmpty, let ok = userInfo?["ok"] as? String else { return nil }
        self.init(token: token, ok: ok == "1", message: userInfo?["message"] as? String ?? "")
    }
}

public enum ViewerLaunch: Equatable, Sendable {
    case handOff([Int32])
    case launch

    public static func decide(viewers: [Int32], me: Int32) -> ViewerLaunch {
        let others = viewers.filter { $0 != me }
        return others.isEmpty ? .launch : .handOff(others)
    }
}
