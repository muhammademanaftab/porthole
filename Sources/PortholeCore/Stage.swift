import CoreGraphics

public enum StageLayout {
    public static let pixels = CGSize(width: 8192, height: 4608)
    public static let points = CGSize(width: 4096, height: 2304)
    public static let pixelsPerInch: CGFloat = 218
    public static let topMargin: CGFloat = 64
    public static let cascadeStep: CGFloat = 48
    public static let cascadeSlots = 8
    public static let idleSeconds: Double = 600
    public static let minPixels = CGSize(width: 1024, height: 768)

    public static func viewerMode(screenPoints: CGSize?) -> (pixels: CGSize, points: CGSize) {
        guard let p = screenPoints, p.width >= 1, p.height >= 1 else { return (pixels, points) }
        var w = p.width * 2, h = p.height * 2
        let shrink = min(1, pixels.width / w, pixels.height / h)
        w *= shrink; h *= shrink
        let grow = max(1, minPixels.width / w, minPixels.height / h)
        w = min(w * grow, pixels.width); h = min(h * grow, pixels.height)
        let ew = CGFloat(Int(w / 4) * 4), eh = CGFloat(Int(h / 4) * 4)
        return (CGSize(width: ew, height: eh), CGSize(width: ew / 2, height: eh / 2))
    }

    public static func shouldRelease(emptySince: Double?, now: Double, idle: Double = idleSeconds) -> Bool {
        guard let since = emptySince else { return false }
        return now - since >= idle
    }

    public static var sizeInMillimeters: CGSize {
        CGSize(width: (pixels.width / pixelsPerInch * 25.4).rounded(), height: (pixels.height / pixelsPerInch * 25.4).rounded())
    }

    public static func origin(besides displays: [CGRect]) -> CGPoint {
        guard let first = displays.first else { return .zero }
        let all = displays.dropFirst().reduce(first) { $0.union($1) }
        return CGPoint(x: all.maxX, y: all.maxY - 1)
    }

    public static func slot(_ index: Int, stage: CGRect, window: CGSize) -> CGPoint {
        let step = CGFloat(((index % cascadeSlots) + cascadeSlots) % cascadeSlots) * cascadeStep
        let x = min(stage.minX + step, max(stage.minX, stage.maxX - window.width))
        let y = min(stage.minY + topMargin + step, max(stage.minY + topMargin, stage.maxY - window.height))
        return CGPoint(x: x, y: y)
    }

    public static func isHiDPIStageMode(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> Bool {
        width > 0 && height > 0 && pixelWidth == width * 2 && pixelHeight == height * 2
    }

    public static func bestMode(_ modes: [(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int)]) -> Int? {
        modes.indices
            .filter { isHiDPIStageMode(width: modes[$0].width, height: modes[$0].height, pixelWidth: modes[$0].pixelWidth, pixelHeight: modes[$0].pixelHeight) }
            .max { modes[$0].width * modes[$0].height < modes[$1].width * modes[$1].height }
    }
}

public enum FullscreenPolicy: String, Equatable, Sendable {
    case stage, leave

    public static let envKey = "PORTHOLE_FULLSCREEN_POLICY"
    public static let exitTimeout: Double = 3
    public static let settleSeconds: Double = 0.3

    public init(environment: [String: String]) {
        self = environment[Self.envKey].flatMap { FullscreenPolicy(rawValue: $0.lowercased()) } ?? .stage
    }

    public func shouldExit(isFullscreen: Bool) -> Bool { self == .stage && isFullscreen }

    public static func looksFullscreen(_ bounds: CGRect, displays: [CGRect]) -> Bool {
        displays.contains { abs($0.minX - bounds.minX) < 1 && abs($0.minY - bounds.minY) < 1
            && abs($0.width - bounds.width) < 1 && abs($0.height - bounds.height) < 1 }
    }

    public static func listed(onScreen: Bool, bounds: CGRect, displays: [CGRect]) -> Bool {
        onScreen || looksFullscreen(bounds, displays: displays)
    }

    public static func exitDone(stillFullscreen: Bool?, before: CGRect, now: CGRect?) -> Bool {
        guard stillFullscreen == false else { return false }
        guard let now else { return true }
        return now != before
    }
}
