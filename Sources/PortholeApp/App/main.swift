import AppKit
import PortholeCore

let appArguments = Array(CommandLine.arguments.dropFirst())
let invokedAs = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent

switch AppCommand.route(appArguments, invokedAs: invokedAs) {
case .help:
    print("\(hostUsage)\n\n\(viewerUsage)")
    exit(0)
case .viewer:
    if let status = ViewerCLI.run(appArguments) { exit(status) }
case .host:
    switch HostCommand.parse(arguments: appArguments, environment: ProcessInfo.processInfo.environment) {
    case .agentPlist:
        FileHandle.standardOutput.write(LaunchAgent.plistData(executableName: Bundle.main.executableURL?.lastPathComponent ?? CLITool.host.rawValue) ?? Data())
        exit(0)
    case .watchdog:
        WatchdogRunner.run()
    case .app:
        if let status = HostCLI.run(appArguments) { exit(status) }
    }
}

HostSignals.install()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ViewerApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
