// hobo-ui: `hobo ui`'s driver inside a macOS guest (designs/hobo-ui.md). hobo-agent fetches it
// from the host on first use each boot and runs it as the guest user in the desktop's bootstrap;
// TCC counts it as the agent, which [gui_testing] grants Accessibility and Screen Recording.
import Foundation
import HoboUICore

let arguments = Array(CommandLine.arguments.dropFirst())
let command: any ParsableCommand
do {
    command = try HoboUI.parseAsRoot(arguments)
} catch {
    HoboUI.exit(withError: error)
}
let json = arguments.contains("--json")

do {
    let outcome = try UIDriver(backend: MacBackend(), store: .standard()).run(command)
    print(UIOutput.success(outcome, json: json).stdout)
} catch {
    let (stdout, stderr) = UIOutput.failure(error, json: json, program: "hobo-ui")
    if !stdout.isEmpty { print(stdout) }
    FileHandle.standardError.write(Data((stderr + "\n").utf8))
    exit(1)
}
