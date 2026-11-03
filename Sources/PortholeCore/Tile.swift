import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public let iconTopic = "porthole-icon"

public enum AppIcon {
    public static let pixels = 512
    public static let maxBytes = 2_000_000
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func attributes(win: UInt32) -> [String: String] { ["win": String(win)] }

    public static func window(from attributes: [String: String]) -> UInt32? {
        guard let s = attributes["win"], let id = UInt32(s), String(id) == s else { return nil }
        return id
    }

    public static func isAcceptable(_ data: Data) -> Bool {
        data.count > pngSignature.count && data.count <= maxBytes && Array(data.prefix(pngSignature.count)) == pngSignature
    }

    public static func png(from image: CGImage, pixels: Int = pixels) -> Data? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    public static func image(fromPNG data: Data) -> CGImage? {
        guard isAcceptable(data), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

public enum ICNS {
    public static let entries: [(type: String, pixels: Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512),
    ]

    public static func encode(_ images: [(type: String, png: Data)]) -> Data {
        var body = Data()
        for (type, png) in images where type.utf8.count == 4 {
            body.append(contentsOf: Array(type.utf8))
            body.append(bigEndian: UInt32(png.count + 8))
            body.append(png)
        }
        var out = Data("icns".utf8)
        out.append(bigEndian: UInt32(body.count + 8))
        return out + body
    }

    public static func make(fromPNG data: Data) -> Data? {
        guard let image = AppIcon.image(fromPNG: data) else { return nil }
        var rendered: [Int: Data] = [:]
        var images: [(type: String, png: Data)] = []
        for e in entries {
            if rendered[e.pixels] == nil { rendered[e.pixels] = AppIcon.png(from: image, pixels: e.pixels) }
            guard let png = rendered[e.pixels] else { return nil }
            images.append((e.type, png))
        }
        return encode(images)
    }
}

private extension Data {
    mutating func append(bigEndian v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)])
    }
}

public enum TileBundle {
    public static let executable = "porthole-tile"
    public static let iconFile = "AppIcon"
    public static let idPrefix = "io.github.muhammademanaftab.porthole.tile."
    public static let fallbackName = "Porthole Portal"

    public static func displayName(forApp app: String) -> String {
        let clean = String(String.UnicodeScalarView(app.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallbackName : clean
    }

    public static func fileName(forApp app: String) -> String {
        var name = displayName(forApp: app).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(64)).trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? fallbackName : name) + ".app"
    }

    public static func executableName(forApp app: String) -> String {
        String(fileName(forApp: app).dropLast(4))
    }

    public static func bundleID(forApp app: String) -> String {
        let name = displayName(forApp: app)
        let ascii = String(name.unicodeScalars.prefix(40).map { s -> Character in
            s.isASCII && (CharacterSet.alphanumerics.contains(s)) ? Character(s) : "-"
        })
        var hash: UInt32 = 2_166_136_261
        for b in name.utf8 { hash = (hash ^ UInt32(b)) &* 16_777_619 }
        return idPrefix + ascii + "-" + String(format: "%08x", hash)
    }

    public static let digestKey = "PortholeHelperDigest"

    public static func infoPlist(forApp app: String, helperDigest: String) -> [String: Any] {
        let name = displayName(forApp: app)
        return [
            "CFBundleIdentifier": bundleID(forApp: app),
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": executableName(forApp: app),
            "CFBundleIconFile": iconFile,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            digestKey: helperDigest,
        ]
    }

    public static func infoPlistData(forApp app: String, helperDigest: String) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: infoPlist(forApp: app, helperDigest: helperDigest), format: .xml, options: 0)
    }
}

public struct TileEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case activate, quit }

    public static let notification = "io.github.muhammademanaftab.porthole.tile"

    public var kind: Kind
    public var token: String

    public init(_ kind: Kind, token: String) { self.kind = kind; self.token = token }

    public var userInfo: [String: String] { ["event": kind.rawValue, "token": token] }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?["event"] as? String, let kind = Kind(rawValue: raw),
              let token = userInfo?["token"] as? String, !token.isEmpty else { return nil }
        self.init(kind, token: token)
    }
}

public enum TileArguments {
    public static func make(token: String, viewer: Int32) -> [String] { ["--tile", token, "--viewer", String(viewer)] }

    public static func parse(_ args: [String]) -> (token: String, viewer: Int32)? {
        var token: String?
        var viewer: Int32?
        var i = 0
        while i < args.count {
            if i + 1 < args.count, args[i] == "--tile" { token = args[i + 1]; i += 2; continue }
            if i + 1 < args.count, args[i] == "--viewer" { viewer = Int32(args[i + 1]); i += 2; continue }
            i += 1
        }
        guard let token, !token.isEmpty, let viewer, viewer > 0 else { return nil }
        return (token, viewer)
    }
}
