import Foundation

public enum LaunchAgent {
    public static let label = "io.github.muhammademanaftab.porthole"
    public static let launchedEnvKey = "PORTHOLE_LAUNCH_AGENT"

    public static func plist(executable: String, logDirectory: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": [launchedEnvKey: "1"],
            "StandardOutPath": logDirectory + "/host.out.log",
            "StandardErrorPath": logDirectory + "/host.out.log",
        ]
    }

    public static func plistData(executable: String, logDirectory: String) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: plist(executable: executable, logDirectory: logDirectory), format: .xml, options: 0)
    }
}
