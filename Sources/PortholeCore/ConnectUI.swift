import Foundation

public struct CodeEntry: Equatable, Sendable {
    public static let length = 6
    public private(set) var digits: [String] = Array(repeating: "", count: length)

    public init() {}

    public var code: String { digits.joined() }
    public var isComplete: Bool { digits.allSatisfy { !$0.isEmpty } }

    public mutating func type(_ text: String, at index: Int, replacing: Bool = false) -> Int {
        guard digits.indices.contains(index) else { return max(0, min(index, Self.length - 1)) }
        var typed = text.filter { $0.isASCII && $0.isNumber }.map(String.init)
        let old = digits[index]
        if !replacing, !old.isEmpty, typed.count > 1 {
            if typed.first == old { typed.removeFirst() } else if typed.last == old { typed.removeLast() }
        }
        guard !typed.isEmpty else {
            digits[index] = ""
            return index
        }
        var i = index
        for d in typed where i < Self.length {
            digits[i] = d
            i += 1
        }
        return min(i, Self.length - 1)
    }

    public mutating func backspace(at index: Int) -> Int {
        guard digits.indices.contains(index) else { return 0 }
        if !digits[index].isEmpty { digits[index] = ""; return index }
        guard index > 0 else { return 0 }
        digits[index - 1] = ""
        return index - 1
    }

    public mutating func clear() { digits = Array(repeating: "", count: Self.length) }
}

public enum HostBadge: Equatable, Sendable { case ready, needsPairing, older, offline }

public extension DiscoveredHost {
    func badge(trusted: Bool) -> HostBadge {
        switch status {
        case .notFound: return .offline
        case .older: return .older
        case .online: return trusted ? .ready : .needsPairing
        }
    }

    var statusText: String {
        switch status {
        case .online: return "Online"
        case .older: return "Older host"
        case .notFound: return "Offline"
        }
    }

    func detail(address: String) -> String {
        var via: [String] = []
        if viaBonjour { via.append("this network") }
        if viaTailscale { via.append("Tailscale") }
        var parts = [address]
        if !via.isEmpty { parts.append(via.joined(separator: " and ")) } else if saved { parts.append("saved") }
        return parts.joined(separator: " · ")
    }
}

public extension HostBadge {
    var help: String {
        switch self {
        case .ready: return "Paired. Connect to see its windows."
        case .needsPairing: return "Not paired yet. Connect to ask that Mac for a pairing code."
        case .older: return "This Mac runs an older Porthole Host. Connect with its password."
        case .offline: return "Not found right now. It may be asleep or off this network."
        }
    }
}

public func connectStatus(found: Int, scanning: Bool) -> String {
    if scanning && found == 0 { return "Looking for Macs…" }
    if found == 0 { return "No Macs found. Connect by address below." }
    return "\(found) Mac\(found == 1 ? "" : "s") online\(scanning ? ", still looking…" : "")"
}

public let galleryScreens = ["connect", "code", "picker", "loading", "empty", "locked", "nomatch", "settings", "portal", "reconnecting"]

public let hostGalleryScreens = ["settings", "sharing", "help", "menu", "pairing"]

public let appGalleryScreens = galleryScreens + hostGalleryScreens.filter { !galleryScreens.contains($0) }

public func galleryScreen(_ args: [String], screens: [String] = galleryScreens) -> String? {
    guard args.first == "gallery", let first = screens.first else { return nil }
    if args.count == 1 { return first }
    guard args.count == 2, screens.contains(args[1]) else { return nil }
    return args[1]
}
