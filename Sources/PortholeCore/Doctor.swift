import CoreGraphics
import Foundation

public struct DisplayRect: Equatable, Sendable {
    public var id: UInt32
    public var bounds: CGRect
    public var isStage: Bool
    public init(id: UInt32, bounds: CGRect, isStage: Bool) { self.id = id; self.bounds = bounds; self.isStage = isStage }
}

public enum WindowPlacement: Equatable, Sendable {
    case onDisplay([UInt32])
    case partlyOff(Double)
    case onStage
    case offDisplay

    public var flagged: Bool {
        switch self {
        case .onDisplay: return false
        default: return true
        }
    }

    public var label: String {
        switch self {
        case .onDisplay(let ids): return "on display \(ids.map(String.init).joined(separator: "+"))"
        case .partlyOff(let f): return "partly off-display (\(Int((f * 100).rounded()))% visible)"
        case .onStage: return "on the Porthole Stage"
        case .offDisplay: return "OFF every display"
        }
    }
}

public func placeWindow(_ w: CGRect, displays: [DisplayRect]) -> WindowPlacement {
    let area = w.width * w.height
    if displays.contains(where: { $0.isStage && $0.bounds.intersects(w) }) { return .onStage }
    let physical = displays.filter { !$0.isStage }
    let hits = physical.filter { $0.bounds.intersects(w) }
    guard !hits.isEmpty, area > 0 else { return .offDisplay }
    let visible = hits.reduce(0.0) { sum, d in
        let i = d.bounds.intersection(w)
        return sum + Double(i.width * i.height)
    }
    let fraction = min(1, visible / Double(area))
    return fraction < 0.5 ? .partlyOff(fraction) : .onDisplay(hits.map(\.id))
}

public enum CheckStatus: String, Sendable {
    case ok, warn, fail, info

    var mark: String {
        switch self {
        case .ok: return "✓"
        case .warn: return "!"
        case .fail: return "✗"
        case .info: return "·"
        }
    }
}

public struct DoctorCheck: Equatable, Sendable {
    public var section: String
    public var name: String
    public var status: CheckStatus
    public var detail: String
    public init(_ section: String, _ name: String, _ status: CheckStatus, _ detail: String) {
        self.section = section; self.name = name; self.status = status; self.detail = detail
    }
}

public func renderDoctor(_ checks: [DoctorCheck], header: String) -> String {
    var out = [header]
    var section = ""
    let width = min(22, checks.map(\.name.count).max() ?? 10)
    for c in checks {
        if c.section != section {
            section = c.section
            out.append("")
            out.append(section)
        }
        let lines = c.detail.split(separator: "\n", omittingEmptySubsequences: false)
        out.append("  \(c.status.mark) \(c.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(lines.first ?? "")")
        for more in lines.dropFirst() { out.append("    \(String(repeating: " ", count: width))  \(more)") }
    }
    let fails = checks.filter { $0.status == .fail }.count, warns = checks.filter { $0.status == .warn }.count
    out.append("")
    out.append(fails == 0 && warns == 0 ? "No problems found." : "\(fails) problem(s), \(warns) warning(s).")
    return out.joined(separator: "\n")
}

public func hostRunningCheck(status: [String: Any]?, pids: [Int32], now: Date = Date()) -> DoctorCheck {
    guard !pids.isEmpty else { return DoctorCheck("Host", "running", .fail, "Porthole isn't sharing this Mac right now (it isn't running, or Share this Mac is off).") }
    guard let status else {
        return DoctorCheck("Host", "running", .warn, "pid \(pids.map(String.init).joined(separator: ", ")), but it didn't answer on 127.0.0.1 (older build, still starting, or hung).")
    }
    let pid = status["pid"] as? Int ?? 0
    let started = (status["started"] as? String).flatMap { LogTime.parse($0) }
    let updated = (status["updated"] as? String).flatMap { LogTime.parse($0) }
    var detail = "pid \(pid)" + (started.map { ", up \(formatDuration(now.timeIntervalSince($0)))" } ?? "") + ", \(status["state"] as? String ?? "?")"
    if pids.count > 1 { detail += "\n\(pids.count) host processes: \(pids.map(String.init).joined(separator: ", "))" }
    if let updated, now.timeIntervalSince(updated) > 10 {
        return DoctorCheck("Host", "running", .warn, detail + "\nits main thread last reported \(formatDuration(now.timeIntervalSince(updated))) ago; it may be hung")
    }
    let connected = status["connected"] as? Bool ?? false
    return DoctorCheck("Host", "running", connected && pids.count == 1 ? .ok : .warn, detail + (connected ? "" : "\nnot connected to its own LiveKit room"))
}

public func stageCheck(_ stage: [String: Any]?, now: Date = Date()) -> DoctorCheck {
    guard let stage else { return DoctorCheck("Host", "Stage", .info, "unknown (the host didn't answer)") }
    guard stage["ready"] as? Bool == true else { return DoctorCheck("Host", "Stage", .ok, "not in use (created when a viewer opens a window)") }
    var detail = "display \(stage["display"] as? Int ?? 0)"
    if let b = stage["bounds"] as? [Double], b.count == 4 { detail += " at \(Int(b[0])),\(Int(b[1])) \(Int(b[2]))x\(Int(b[3]))" }
    detail += ", \(stage["parked"] as? Int ?? 0) window(s) parked"
    if let idle = (stage["idleSince"] as? String).flatMap({ LogTime.parse($0) }) {
        let limit = Double(stage["idleLimit"] as? Int ?? 600)
        detail += ", empty for \(formatDuration(now.timeIntervalSince(idle))); released after \(formatDuration(limit))"
    }
    return DoctorCheck("Host", "Stage", .ok, detail)
}

public func renderProblems(_ buckets: [LogBucket]) -> String {
    guard !buckets.isEmpty else { return "none" }
    return buckets.map { b in
        let when = b.last.map { LogTime.format($0, milliseconds: false) } ?? "?"
        return "\(b.count)× \(b.level.rawValue) \(b.event)  (last \(when))\n   \(b.sample.count > 140 ? String(b.sample.prefix(140)) + "…" : b.sample)"
    }.joined(separator: "\n")
}
