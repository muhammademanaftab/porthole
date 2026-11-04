import Foundation
import PortholeCore

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_DFL)

let code: Int32
switch parseCLI(Array(CommandLine.arguments.dropFirst())) {
case .help(let error):
    if let error {
        fail("\(error)\n")
        say(cliUsage)
        code = 2
    } else {
        print(cliUsage)
        code = 0
    }
case .version: code = VersionCommand.run()
case .env(let setOnly, let json): code = EnvCommand.run(setOnly: setOnly, json: json)
case .doctor(let o): code = DoctorCommand.run(o)
case .log(let o): code = LogCommand.run(o)
case .trail(let o): code = TrailCommand.run(o)
case .whyQuit(let n): code = WhyQuitCommand.run(n)
case .report(let o): code = ReportCommand.run(o)
case .share(let o): code = ShareCommand.run(o)
case .forward(let tool, let args): code = Tools.exec(tool, args)
}
exit(code)
