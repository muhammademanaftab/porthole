import Foundation

public struct Scrubber: Sendable {
    public static let mask = "[redacted]"
    public var secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { $0.count >= 6 }.sorted { $0.count > $1.count }
    }

    static let rules: [(String, String)] = [
        (#"(?i)\b(pw|password|passwd|secret|token|share|api_?key|api_?secret|key)=([^&\s"'<>]+)"#, "$1=" + mask),
        (#"(?i)"(password|apiSecret|apiKey|secret|token|pw)"\s*:\s*"[^"]*""#, "\"$1\":\"" + mask + "\""),
        (#"(?i)\b(X-Porthole-Local|Authorization)\s*:\s*\S+(\s+\S+)?"#, "$1: " + mask),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer " + mask),
        (#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#, mask),
        (#"(?i)\b(code|pairing code)(\s*[:=]?\s*)\d{3}[ -]?\d{3}\b"#, "$1$2" + mask),
        (#"(?i)\b([0-9a-f]{8})[0-9a-f]{8}\b"#, "$1…"),
    ]

    static let compiled: [(NSRegularExpression, String)] = rules.compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    public func scrub(_ text: String) -> String {
        var s = text
        for secret in secrets { s = s.replacingOccurrences(of: secret, with: Self.mask) }
        for (re, template) in Self.compiled {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }
}

public func shortID(_ id: String) -> String {
    id.count > 8 ? String(id.prefix(8)) + "…" : id
}
