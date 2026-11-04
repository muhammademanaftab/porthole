import CoreGraphics
import Foundation
import PortholeCore

private func announced(_ actions: [CompanionTracker.Action]) -> [String] {
    actions.map { if case .announce(let m, let who) = $0 { return "\(m.win ?? 0)>\(who)" } else { return "?" } }
}

func companionTests() {
    check("dialogs as windows: on by default", CompanionRules.enabled(stored: nil, environment: [:]))
    check("dialogs as windows: the saved switch turns it off", !CompanionRules.enabled(stored: false, environment: [:]))
    check("dialogs as windows: PORTHOLE_COMPANIONS=1 wins over the switch", CompanionRules.enabled(stored: false, environment: ["PORTHOLE_COMPANIONS": "1"]))
    check("dialogs as windows: PORTHOLE_COMPANIONS=0 turns it off for the run", !CompanionRules.enabled(stored: true, environment: ["PORTHOLE_COMPANIONS": "0"]))
    check("dialogs as windows: a junk saved value means on", CompanionRules.enabled(stored: "no", environment: [:]))

    let info: [String: Any] = ["kCGWindowNumber": NSNumber(value: 42), "kCGWindowOwnerPID": NSNumber(value: 7),
                               "kCGWindowOwnerName": "TextEdit", "kCGWindowLayer": NSNumber(value: 8),
                               "kCGWindowBounds": CGRect(x: 1, y: 2, width: 300, height: 200).dictionaryRepresentation]
    expect("snapshot: read from a CGWindowList entry", WindowSnapshot(cgInfo: info),
           WindowSnapshot(id: 42, pid: 7, owner: "TextEdit", layer: 8, bounds: CGRect(x: 1, y: 2, width: 300, height: 200)))
    check("snapshot: an entry without bounds is skipped", WindowSnapshot(cgInfo: ["kCGWindowNumber": NSNumber(value: 1), "kCGWindowOwnerPID": NSNumber(value: 1)]) == nil)

    let parent = WindowSnapshot(id: 10, pid: 100, owner: "Scratch", layer: 0, bounds: CGRect(x: 200, y: 100, width: 800, height: 600))
    let sheet = WindowSnapshot(id: 11, pid: 100, owner: "Scratch", layer: 0, bounds: CGRect(x: 350, y: 128, width: 500, height: 300))
    let alert = WindowSnapshot(id: 12, pid: 100, owner: "Scratch", layer: 8, bounds: CGRect(x: 3000, y: 300, width: 260, height: 160))
    let farDoc = WindowSnapshot(id: 13, pid: 100, owner: "Scratch", layer: 0, bounds: CGRect(x: 3000, y: 900, width: 600, height: 400))
    let menu = WindowSnapshot(id: 14, pid: 100, owner: "Scratch", layer: 101, bounds: CGRect(x: 300, y: 200, width: 200, height: 300))
    let savePanel = WindowSnapshot(id: 15, pid: 555, owner: "Open and Save Panel Service (Scratch)", layer: 0, bounds: CGRect(x: 300, y: 128, width: 600, height: 400))
    let otherApp = WindowSnapshot(id: 16, pid: 777, owner: "Safari", layer: 0, bounds: CGRect(x: 300, y: 150, width: 600, height: 400))
    let old = WindowSnapshot(id: 9, pid: 100, owner: "Scratch", layer: 0, bounds: CGRect(x: 250, y: 150, width: 400, height: 300))
    let tiny = WindowSnapshot(id: 17, pid: 100, owner: "Scratch", layer: 0, bounds: CGRect(x: 300, y: 150, width: 10, height: 10))
    let all = [parent, sheet, alert, farDoc, menu, savePanel, otherApp, old, tiny]
    let found = CompanionRules.candidates(of: parent, among: all, baseline: [9, 10], excluded: []).map(\.id)
    expect("companions: same-app window over it, modal alert anywhere, and the Save panel service", found, [11, 12, 15])
    check("companions: a new document window far away is not one", !found.contains(13))
    check("companions: menus are left to the picture", !found.contains(14))
    check("companions: another app's window is never one", !found.contains(16))
    check("companions: a window open before sharing is not one", !found.contains(9))
    check("companions: slivers are ignored", !found.contains(17))
    expect("companions: already shared or attached windows are excluded",
           CompanionRules.candidates(of: parent, among: all, baseline: [9, 10], excluded: [11, 15]).map(\.id), [12])

    let offer = CompanionRules.message(child: sheet, parent: parent.bounds, parentID: 10)
    expect("offer: carries the type, child and parent", [offer.t == .companion, offer.win == 11, offer.of == 10], [true, true, true])
    expect("offer: offset from the parent's top-left", [offer.x, offer.y, offer.w, offer.h, offer.pw, offer.ph], [150, 28, 500, 300, 800, 600])
    expect("offer: survives the wire", Message.decode(offer.encoded()), offer)

    let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let picture = CGRect(x: 100, y: 100, width: 800, height: 600)
    expect("placement: an attached sheet sits at the same spot over the portal picture",
           CompanionRules.placement(offset: CGPoint(x: 150, y: 28), size: CGSize(width: 500, height: 300),
                                    parentSize: CGSize(width: 800, height: 600), picture: picture, screen: screen),
           CGRect(x: 250, y: 372, width: 500, height: 300))
    expect("placement: a smaller portal scales the companion with it",
           CompanionRules.placement(offset: CGPoint(x: 150, y: 28), size: CGSize(width: 500, height: 300),
                                    parentSize: CGSize(width: 1600, height: 1200), picture: picture, screen: screen),
           CGRect(x: 175, y: 536, width: 250, height: 150))
    expect("placement: a far-away alert is centred over the portal, a third down",
           CompanionRules.placement(offset: CGPoint(x: 2800, y: 200), size: CGSize(width: 260, height: 160),
                                    parentSize: CGSize(width: 800, height: 600), picture: picture, screen: screen),
           CGRect(x: 370, y: 393, width: 260, height: 160))
    expect("placement: kept on the viewer's screen",
           CompanionRules.placement(offset: CGPoint(x: 700, y: -40), size: CGSize(width: 400, height: 300),
                                    parentSize: CGSize(width: 800, height: 600), picture: CGRect(x: 1000, y: 600, width: 800, height: 600), screen: screen),
           CGRect(x: 1112, y: 645, width: 400, height: 300))

    var tr = CompanionTracker()
    let viewers: Set<String> = ["mac-a", "mac-b"]
    func parents(_ w: WindowSnapshot?, _ v: Set<String> = viewers) -> [UInt32: CompanionTracker.Parent] {
        [10: CompanionTracker.Parent(window: w, baseline: [9, 10], viewers: v)]
    }
    var asked: [[UInt32]] = []
    let a1 = tr.update(parents: parents(parent), windows: [parent, old, sheet, alert]) { _, ids in asked.append(ids); return [11] }
    expect("tracker: AX is asked once about the new windows", asked, [[11, 12]])
    expect("tracker: an attached sheet stays in the picture, the alert is offered to each viewer", announced(a1), ["12>mac-a", "12>mac-b"])
    expect("tracker: the alert is recorded under its parent", tr.parent(of: 12), 10)
    check("tracker: only viewers it was offered to may open it", tr.mayOpen(12, by: "mac-a") && !tr.mayOpen(12, by: "mac-c"))
    asked = []
    let a2 = tr.update(parents: parents(parent), windows: [parent, old, sheet, alert]) { _, ids in asked.append(ids); return [] }
    check("tracker: nothing new means no AX calls and no messages", asked.isEmpty && a2.isEmpty)
    let a3 = tr.update(parents: parents(parent, viewers.union(["mac-c"])), windows: [parent, sheet, alert]) { _, _ in [] }
    expect("tracker: a viewer who joins later is offered it once", announced(a3), ["12>mac-c"])
    var movedAlert = alert
    movedAlert.bounds.origin.x += 20
    let a4 = tr.update(parents: parents(parent, viewers.union(["mac-c"])), windows: [parent, sheet, movedAlert]) { _, _ in [] }
    expect("tracker: a moved companion is offered again to everyone", a4.count, 3)
    var farAlert = movedAlert
    farAlert.layer = 0
    let sticky = tr.update(parents: parents(parent, viewers.union(["mac-c"])), windows: [parent, sheet, farAlert]) { _, _ in [] }
    check("tracker: once offered it stays a companion even if it no longer looks like one", sticky.isEmpty && tr.parent(of: 12) == 10)
    let blink = tr.update(parents: parents(parent), windows: [parent, sheet]) { _, _ in [] }
    check("tracker: missing from one window list is not yet gone", blink.isEmpty && tr.parent(of: 12) == 10)
    let a5 = tr.update(parents: parents(parent), windows: [parent, sheet]) { _, _ in [] }
    expect("tracker: missing twice, the alert is reported gone with who was told", a5, [.gone(12, told: ["mac-a", "mac-b", "mac-c"])])
    check("tracker: and forgotten", tr.parent(of: 12) == nil)
    check("tracker: an open for it now is known to be for a closed dialog", tr.wasCompanion(12) && !tr.wasCompanion(11))
    _ = tr.update(parents: parents(parent), windows: [parent, savePanel]) { _, _ in [] }
    let a6 = tr.update(parents: [:], windows: [savePanel]) { _, _ in [] }
    expect("tracker: companions go when their parent stops being shared", a6, [.gone(15, told: viewers)])
    _ = tr.update(parents: parents(parent), windows: [parent, savePanel]) { _, _ in [] }
    expect("tracker: switching the feature off closes every companion", tr.removeAll(), [.gone(15, told: viewers)])
    check("tracker: nothing left after that", tr.records.isEmpty)
    var many = CompanionTracker()
    for i in 0..<100 {
        let w = WindowSnapshot(id: UInt32(1000 + i), pid: 100, owner: "Scratch", layer: 8, bounds: CGRect(x: 300, y: 200, width: 200, height: 100))
        _ = many.update(parents: parents(parent), windows: [parent, w]) { _, _ in [] }
        _ = many.update(parents: [:], windows: []) { _, _ in [] }
    }
    expect("tracker: it remembers only the last 64 closed dialogs", many.retired.count, CompanionTracker.retiredLimit)
}
