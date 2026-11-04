import Foundation
import PortholeCore

func recentPickerTests() {
    let t = Date(timeIntervalSince1970: 1_000_000)
    func r(_ host: String, _ id: UInt32, _ app: String, _ title: String, ago: TimeInterval) -> RecentPortal {
        RecentPortal(host: host, hostName: host == "mini" ? "Mini" : "Air", windowID: id, title: title, app: app, bundle: nil, time: t.addingTimeInterval(-ago))
    }
    let list = [r("mini", 5, "Safari", "Apple", ago: 10), r("air", 9, "Notes", "List", ago: 20), r("mini", 6, "Terminal", "zsh", ago: 30),
                r("mini:7878", 7, "Mail", "Inbox", ago: 40), r("mini", 99, "Gone", "Closed", ago: 50)]
    let live = [WindowInfo(id: 6, app: "Terminal", title: "zsh", bundle: nil, w: 1, h: 1), WindowInfo(id: 5, app: "Safari", title: "Apple", bundle: nil, w: 1, h: 1),
                WindowInfo(id: 70, app: "Mail", title: "Inbox", bundle: nil, w: 1, h: 1), WindowInfo(id: 1, app: "Finder", title: "", bundle: nil, w: 1, h: 1)]
    expect("recent picker: this host's live windows, newest first", RecentPortals.forPicker(list, host: "mini", windows: live).map(\.id), [5, 6, 70])
    expect("recent picker: an address with the default port is the same host", RecentPortals.forPicker(list, host: "MINI:7878", windows: live).map(\.id), [5, 6, 70])
    expect("recent picker: a window that changed its ID is found again by app and title",
           RecentPortals.forPicker([r("mini", 7, "Mail", "Inbox", ago: 1)], host: "mini", windows: live).map(\.id), [70])
    expect("recent picker: a closed window is left out", RecentPortals.forPicker([r("mini", 99, "Gone", "Closed", ago: 1)], host: "mini", windows: live).count, 0)
    expect("recent picker: another host's portals are left out", RecentPortals.forPicker([r("air", 5, "Safari", "Apple", ago: 1)], host: "mini", windows: live).count, 0)
    expect("recent picker: at most the limit", RecentPortals.forPicker(list, host: "mini", windows: live, limit: 2).map(\.id), [5, 6])
    expect("recent picker: one chip per window", RecentPortals.forPicker([r("mini", 5, "Safari", "Apple", ago: 1), r("mini", 5, "Safari", "Apple", ago: 2)],
                                                                         host: "mini", windows: live).count, 1)
    expect("recent picker: nothing before the list arrives", RecentPortals.forPicker(list, host: "mini", windows: []).count, 0)
    expect("recent connect: newest first across hosts, at most 5", RecentPortals.forConnect(list).map(\.windowID), [5, 9, 6, 7, 99])
    expect("recent connect: the limit", RecentPortals.forConnect(list, limit: 2).map(\.windowID), [5, 9])
    expect("recent chip: the title, or the app when untitled", [RecentPortals.chipTitle(list[0]), RecentPortals.chipTitle(r("mini", 1, "Finder", "", ago: 0))], ["Apple", "Finder"])
    expect("recent chip: app, host and age", RecentPortals.chipDetail(list[0], now: t.addingTimeInterval(300)), "Safari · Mini · 5m ago")
    expect("recent chip: just now", RecentPortals.chipDetail(list[0], now: t), "Safari · Mini · just now")
    expect("recent chip: hours", RecentPortals.chipDetail(list[0], now: t.addingTimeInterval(7200)), "Safari · Mini · 2h ago")
    expect("recent chip: an untitled window shows the host only", RecentPortals.chipDetail(r("mini", 1, "Finder", "", ago: 0), now: t.addingTimeInterval(86400 * 3)), "Mini · 3d ago")
    check("recent: same host ignores case and the default port", RecentPortals.sameHost("Mini.local", "mini.local:7878") && !RecentPortals.sameHost("mini", "air"))
}
