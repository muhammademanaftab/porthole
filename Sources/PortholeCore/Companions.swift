import CoreGraphics
import Foundation

public struct WindowSnapshot: Equatable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var owner: String
    public var layer: Int
    public var bounds: CGRect
    public var bundle: String?

    public init(id: UInt32, pid: Int32, owner: String, layer: Int, bounds: CGRect, bundle: String? = nil) {
        self.id = id; self.pid = pid; self.owner = owner; self.layer = layer; self.bounds = bounds; self.bundle = bundle
    }

    public init?(cgInfo d: [String: Any]) {
        guard let n = (d["kCGWindowNumber"] as? NSNumber)?.uint32Value,
              let pid = (d["kCGWindowOwnerPID"] as? NSNumber)?.int32Value,
              let b = d["kCGWindowBounds"] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        self.init(id: n, pid: pid, owner: d["kCGWindowOwnerName"] as? String ?? "",
                  layer: (d["kCGWindowLayer"] as? NSNumber)?.intValue ?? 0, bounds: rect)
    }
}

public enum CompanionRules {
    public static let settingKey = "showDialogsAsWindows"
    public static let envKey = "PORTHOLE_COMPANIONS"
    public static let nearMargin: CGFloat = 48
    public static let layers = 0...100
    public static let minSize = CGSize(width: 24, height: 24)
    public static let pollSeconds: Double = 0.4
    public static let panelServices = ["Open and Save Panel Service", "openAndSavePanelService", "QuickLookUIService", "PrintUIService", "PrinterProxy"]

    public static func enabled(stored: Any?, environment: [String: String]) -> Bool {
        switch environment[envKey] {
        case "0": return false
        case "1": return true
        default: return stored as? Bool ?? true
        }
    }

    public static func isPanelService(_ owner: String) -> Bool {
        panelServices.contains { owner.localizedCaseInsensitiveContains($0) }
    }

    public static func isNear(_ child: CGRect, _ parent: CGRect) -> Bool {
        parent.insetBy(dx: -nearMargin, dy: -nearMargin).intersects(child)
    }

    public static func isBlocked(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return WindowFilter.blockedBundles.contains(bundle) || WindowFilter.systemBundles.contains(bundle)
    }

    public static func candidates(of parent: WindowSnapshot, among windows: [WindowSnapshot], baseline: Set<UInt32>,
                                  excluded: Set<UInt32>, appActive: Bool) -> [WindowSnapshot] {
        guard !isBlocked(parent.bundle) else { return [] }
        return windows.filter { c in
            guard c.id != parent.id, !baseline.contains(c.id), !excluded.contains(c.id), layers.contains(c.layer),
                  c.bounds.width >= minSize.width, c.bounds.height >= minSize.height, !isBlocked(c.bundle) else { return false }
            if c.pid == parent.pid { return isNear(c.bounds, parent.bounds) || c.layer > 0 }
            return appActive && isPanelService(c.owner)
        }
    }

    public static func message(child: WindowSnapshot, parent: CGRect, parentID: UInt32) -> Message {
        var m = Message(.companion)
        m.win = child.id
        m.of = parentID
        m.x = child.bounds.minX - parent.minX
        m.y = child.bounds.minY - parent.minY
        m.w = child.bounds.width
        m.h = child.bounds.height
        m.pw = parent.width
        m.ph = parent.height
        return m
    }

    public static func placement(offset: CGPoint, size: CGSize, parentSize: CGSize, picture: CGRect, screen: CGRect) -> CGRect {
        guard parentSize.width > 0, parentSize.height > 0, picture.width > 0 else {
            return CGRect(origin: picture.origin, size: size)
        }
        let scale = picture.width / parentSize.width
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        let hostRect = CGRect(origin: offset, size: size)
        let attached = isNear(hostRect, CGRect(origin: .zero, size: parentSize))
        var x: CGFloat, top: CGFloat
        if attached {
            x = picture.minX + offset.x * scale
            top = picture.maxY - offset.y * scale
        } else {
            x = picture.midX - w / 2
            top = picture.maxY - max(0, (picture.height - h) / 3)
        }
        var r = CGRect(x: x.rounded(), y: (top - h).rounded(), width: w, height: h)
        if screen.width > 0, screen.height > 0 {
            r.origin.x = min(max(r.minX, screen.minX), max(screen.minX, screen.maxX - r.width))
            r.origin.y = min(max(r.minY, screen.minY), max(screen.minY, screen.maxY - r.height))
        }
        return r
    }
}

public struct CompanionTracker: Sendable {
    public struct Record: Equatable, Sendable {
        public var parent: UInt32
        public var bounds: CGRect
        public var parentBounds: CGRect
        public var told: Set<String>
        public var declined: Set<String>
    }

    public struct Parent: Sendable {
        public var window: WindowSnapshot?
        public var baseline: Set<UInt32>
        public var viewers: Set<String>
        public var appActive: Bool

        public init(window: WindowSnapshot?, baseline: Set<UInt32>, viewers: Set<String>, appActive: Bool = false) {
            self.window = window; self.baseline = baseline; self.viewers = viewers; self.appActive = appActive
        }
    }

    public enum Action: Equatable, Sendable {
        case announce(Message, to: String)
        case gone(UInt32, told: Set<String>)
    }

    public static let missesBeforeGone = 2
    public static let retiredLimit = 64

    public private(set) var records: [UInt32: Record] = [:]
    public private(set) var attached: Set<UInt32> = []
    public private(set) var retired: [UInt32] = []
    private var misses: [UInt32: Int] = [:]

    public init() {}

    public func parent(of child: UInt32) -> UInt32? { records[child]?.parent }

    public func mayOpen(_ child: UInt32, by who: String, parentViewers: Set<String>) -> Bool {
        records[child]?.told.contains(who) == true && parentViewers.contains(who)
    }

    public mutating func release(_ child: UInt32, by who: String) {
        records[child]?.told.remove(who)
        records[child]?.declined.insert(who)
    }

    public mutating func parentReleased(_ parent: UInt32, by who: String) {
        for id in records.keys where records[id]?.parent == parent {
            records[id]?.told.remove(who)
            records[id]?.declined.remove(who)
        }
    }

    public func wasCompanion(_ id: UInt32) -> Bool { records[id] == nil && retired.contains(id) }

    private mutating func retire(_ id: UInt32) -> Action? {
        misses[id] = nil
        guard let r = records.removeValue(forKey: id) else { return nil }
        retired.removeAll { $0 == id }
        retired.append(id)
        if retired.count > Self.retiredLimit { retired.removeFirst(retired.count - Self.retiredLimit) }
        return .gone(id, told: r.told)
    }

    public mutating func update(parents: [UInt32: Parent], windows: [WindowSnapshot],
                                attachedTo: (UInt32, [UInt32]) -> Set<UInt32>) -> [Action] {
        var actions: [Action] = []
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parentIDs = Set(parents.keys)
        var claimed: [UInt32: (WindowSnapshot, UInt32)] = [:]
        for (id, r) in records {
            if parents[r.parent]?.window != nil, let w = byID[id] { claimed[id] = (w, r.parent) }
        }
        for pid in parents.keys.sorted() {
            guard let p = parents[pid], let pw = p.window else { continue }
            let excluded = parentIDs.union(attached).union(claimed.keys)
            var found = CompanionRules.candidates(of: pw, among: windows, baseline: p.baseline, excluded: excluded, appActive: p.appActive)
            let unknown = found.map(\.id).filter { records[$0] == nil }
            if !unknown.isEmpty {
                let stuck = attachedTo(pid, unknown)
                attached.formUnion(stuck)
                found.removeAll { stuck.contains($0.id) }
            }
            for c in found { claimed[c.id] = (c, pid) }
        }
        attached.formIntersection(Set(byID.keys))
        for id in records.keys.sorted() where claimed[id] == nil {
            let parentLeft = parents[records[id]?.parent ?? 0] == nil
            misses[id, default: 0] += 1
            if parentLeft || misses[id, default: 0] >= Self.missesBeforeGone, let a = retire(id) { actions.append(a) }
        }
        for (id, (c, pid)) in claimed.sorted(by: { $0.key < $1.key }) {
            guard let p = parents[pid], let pw = p.window else { continue }
            misses[id] = nil
            retired.removeAll { $0 == id }
            var r = records[id] ?? Record(parent: pid, bounds: c.bounds, parentBounds: pw.bounds, told: [], declined: [])
            let moved = r.bounds != c.bounds || r.parentBounds != pw.bounds
            r.bounds = c.bounds
            r.parentBounds = pw.bounds
            r.told.formIntersection(p.viewers)
            r.declined.formIntersection(p.viewers)
            let m = CompanionRules.message(child: c, parent: pw.bounds, parentID: pid)
            for v in p.viewers.sorted() where !r.declined.contains(v) && (moved || !r.told.contains(v)) {
                actions.append(.announce(m, to: v))
                r.told.insert(v)
            }
            records[id] = r
        }
        return actions
    }

    public mutating func removeAll() -> [Action] {
        let out = records.keys.sorted().compactMap { retire($0) }
        attached.removeAll()
        return out
    }
}
