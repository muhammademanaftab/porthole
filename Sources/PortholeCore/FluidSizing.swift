import CoreGraphics

public struct LiveResizeThrottle: Sendable {
    public static let interval: Double = 1.0 / 12

    public private(set) var lastSent: CGSize?
    private var lastAt: Double = -.infinity

    public init() {}

    public static func rounded(_ s: CGSize) -> CGSize {
        CGSize(width: s.width.rounded(), height: s.height.rounded())
    }

    public mutating func during(_ size: CGSize, now: Double) -> CGSize? {
        let s = Self.rounded(size)
        guard s != lastSent, now - lastAt >= Self.interval else { return nil }
        lastSent = s
        lastAt = now
        return s
    }

    public mutating func finish(_ size: CGSize, now: Double) -> CGSize {
        let s = Self.rounded(size)
        lastSent = s
        lastAt = now
        return s
    }
}

public struct SizeFollowSchedule: Sendable {
    public static let lead: Double = 0.1
    public static let trailing: [Double] = [0.4, 0.8]

    public enum Step: Equatable, Sendable {
        case lead
        case trailing(generation: Int)
    }

    public private(set) var generation = 0
    public private(set) var leadPending = false

    public init() {}

    public mutating func request() -> [(delay: Double, step: Step)] {
        generation += 1
        var out: [(Double, Step)] = []
        if !leadPending {
            leadPending = true
            out.append((Self.lead, .lead))
        }
        for d in Self.trailing { out.append((d, .trailing(generation: generation))) }
        return out
    }

    public mutating func shouldRun(_ step: Step) -> Bool {
        switch step {
        case .lead:
            leadPending = false
            return true
        case .trailing(let g):
            return g == generation
        }
    }
}

public struct ResizePlan: Equatable, Sendable {
    public var size: CGSize
    public var origin: CGPoint?

    public init(size: CGSize, origin: CGPoint?) { self.size = size; self.origin = origin }

    public static func make(window: CGRect, asked: CGSize, areas: [CGRect]) -> ResizePlan {
        func overlap(_ a: CGRect) -> CGFloat {
            let i = a.intersection(window)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let area = areas.max(by: { overlap($0) < overlap($1) }), overlap(area) > 0 else {
            return ResizePlan(size: asked, origin: nil)
        }
        let size = CGSize(width: min(asked.width, area.width), height: min(asked.height, area.height))
        var x = window.minX, y = window.minY
        if x + size.width > area.maxX { x = max(area.minX, area.maxX - size.width) }
        if y + size.height > area.maxY { y = max(area.minY, area.maxY - size.height) }
        if y < area.minY { y = area.minY }
        let origin = CGPoint(x: x, y: y)
        return ResizePlan(size: size, origin: origin == window.origin ? nil : origin)
    }
}

public enum PortalSizing {
    public static let tolerance: CGFloat = 2

    public static func differs(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = tolerance) -> Bool {
        abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    public static func hostShouldReply(asked: CGSize, actual: CGSize) -> Bool {
        differs(asked, actual)
    }

    public static func snap(asked: CGSize, lastSent: CGSize?, actual: CGSize, liveResizing: Bool, screen: CGSize) -> CGSize? {
        guard !liveResizing, let last = lastSent, !differs(asked, last, tolerance: 0.5),
              differs(actual, last), actual.width > 0, actual.height > 0 else { return nil }
        let f = min(1, screen.width / actual.width, screen.height / actual.height)
        return CGSize(width: (actual.width * f).rounded(), height: (actual.height * f).rounded())
    }

    public struct Limits: Equatable, Sendable {
        public var minimum: CGSize
        public var maximum: CGSize

        public init(minimum: CGSize = .zero, maximum: CGSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) {
            self.minimum = minimum; self.maximum = maximum
        }

        public mutating func learn(asked: CGSize, actual: CGSize) {
            if actual.width > asked.width + tolerance { minimum.width = max(minimum.width, actual.width) }
            if actual.height > asked.height + tolerance { minimum.height = max(minimum.height, actual.height) }
            if actual.width < asked.width - tolerance { maximum.width = min(maximum.width, actual.width) }
            if actual.height < asked.height - tolerance { maximum.height = min(maximum.height, actual.height) }
            if maximum.width < minimum.width { maximum.width = minimum.width }
            if maximum.height < minimum.height { maximum.height = minimum.height }
        }
    }
}

public enum PictureFit: Equatable, Sendable {
    case fit, fill

    public static let settleSeconds: Double = 1.5
    public static let aspectTolerance: Double = 0.02

    public static func mode(liveResizing: Bool, video: CGSize?, view: CGSize, sinceResizeEnd: Double?) -> PictureFit {
        if liveResizing { return .fill }
        guard let since = sinceResizeEnd, since < settleSeconds, let v = video,
              v.width > 0, v.height > 0, view.width > 0, view.height > 0 else { return .fit }
        let a = v.width / v.height, b = view.width / view.height
        return abs(a - b) / b > aspectTolerance ? .fill : .fit
    }
}

public func filledRect(content: CGSize, in bounds: CGRect) -> CGRect {
    guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let scale = max(bounds.width / content.width, bounds.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
}
