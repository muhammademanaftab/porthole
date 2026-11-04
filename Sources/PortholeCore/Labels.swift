import CoreGraphics

public extension WindowInfo {
    var pickerLabel: String { title.isEmpty ? app : "\(app) — \(title)" }

    func portalTitle(host: String) -> String {
        title.isEmpty ? "\(app) (\(host))" : "\(title) · \(app) (\(host))"
    }
}

public func hostMenuTitle(state: String, openWindows n: Int) -> String {
    "Porthole: \(state)\(n > 0 ? " · \(n) window\(n == 1 ? "" : "s") open" : "")"
}

public func hostStatusLine(state: String, openWindows n: Int) -> String {
    n > 0 && state == "Sharing" ? "Sharing \(n) window\(n == 1 ? "" : "s")" : state == "Sharing" ? "Ready to share" : state
}

public func viewerCountLabel(_ n: Int) -> String {
    n <= 1 ? "" : "\(n) viewers"
}

public func portalContentSize(remote size: CGSize, screen: CGSize) -> CGSize {
    CGSize(width: min(max(size.width, 320), screen.width), height: min(max(size.height, 200), screen.height))
}

public func pickerStatus(_ n: Int) -> String {
    n == 0 ? "No windows to share on the host." : "\(n) window\(n == 1 ? "" : "s"). Click one to open it."
}
