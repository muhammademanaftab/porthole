import CoreGraphics
import Foundation

public enum LockNotice {
    public static let list = "This Mac's screen is locked, and macOS hides all windows while it is locked. Unlock it (for example with Screen Sharing), then refresh."
    public static let control = "This Mac's screen is locked, so typing and clicks go to the lock screen. Unlock it (for example with Screen Sharing) to control windows."
}

public extension WindowInfo {
    var sizeLabel: String { windowSizeLabel(w, h) }

    var displayTitle: String { title.isEmpty ? app : title }

    var displaySubtitle: String { title.isEmpty ? sizeLabel : "\(app) · \(sizeLabel)" }
}

public func wholeNumber(_ v: Double) -> Int {
    v.isFinite ? Int(max(-1e9, min(1e9, v.rounded()))) : 0
}

public func windowSizeLabel(_ w: Double, _ h: Double) -> String {
    "\(wholeNumber(w))\u{00D7}\(wholeNumber(h))"
}

public func searchTokens(_ query: String) -> [String] {
    query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

public func filterWindows(_ list: [WindowInfo], query: String) -> [WindowInfo] {
    let tokens = searchTokens(query)
    guard !tokens.isEmpty else { return list }
    return list.filter { w in
        let hay = "\(w.app) \(w.title)"
        return tokens.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public enum PickerNotice: Equatable, Sendable {
    case loading
    case empty
    case locked
    case noMatches(String)
    case error(String)

    public var symbol: String {
        switch self {
        case .loading: return "hourglass"
        case .empty: return "macwindow.badge.plus"
        case .locked: return "lock.fill"
        case .noMatches: return "magnifyingglass"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    public var title: String {
        switch self {
        case .loading: return "Connecting…"
        case .empty: return "No Windows to Share"
        case .locked: return "Screen Is Locked"
        case .noMatches: return "No Matches"
        case .error: return "Can't Show Windows"
        }
    }

    public var message: String {
        switch self {
        case .loading: return "Asking the host for its windows."
        case .empty: return "Open a window on the host, then refresh."
        case .locked: return LockNotice.list
        case .noMatches(let q): return "No window matches \u{201C}\(q)\u{201D}."
        case .error(let msg): return msg
        }
    }
}

public func pickerNotice(loaded: Bool, total: Int, shown: Int, query: String, error: String?) -> PickerNotice? {
    if total == 0, let error, !error.isEmpty { return error == LockNotice.list ? .locked : .error(error) }
    if !loaded { return .loading }
    if total == 0 { return .empty }
    if shown == 0 { return .noMatches(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

public func pickerCountLabel(total: Int, shown: Int) -> String {
    let all = "\(total) window\(total == 1 ? "" : "s")"
    return shown == total ? all : "\(shown) of \(all)"
}

public let thumbTopic = "porthole-thumb"

public enum WindowThumbnail {
    public static let maxPixels = CGSize(width: 480, height: 300)
    public static let maxBytes = 200_000
    public static let quality = 0.6
    public static let maxPerList = 40
    public static let cacheFresh: TimeInterval = 6
    public static let minRequestGap: TimeInterval = 2

    public static func shouldServe(lastAsked: Date?, now: Date) -> Bool {
        guard let lastAsked else { return true }
        let gap = now.timeIntervalSince(lastAsked)
        return gap >= minRequestGap || gap < 0
    }
    private static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

    public static func pixelSize(window: CGSize, limit: CGSize = maxPixels) -> CGSize? {
        guard window.width >= 1, window.height >= 1, limit.width >= 1, limit.height >= 1 else { return nil }
        let s = min(limit.width / window.width, limit.height / window.height, 1)
        return CGSize(width: max(1, (window.width * s).rounded()), height: max(1, (window.height * s).rounded()))
    }

    public static func isAcceptable(_ data: Data) -> Bool {
        data.count > jpegSignature.count && data.count <= maxBytes && Array(data.prefix(jpegSignature.count)) == jpegSignature
    }

    public static func requests(for list: [WindowInfo]) -> [UInt32] {
        Array(list.prefix(maxPerList).map(\.id))
    }
}
