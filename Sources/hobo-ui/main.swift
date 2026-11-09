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

func emit(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

struct Failure: Encodable {
    var error: String
    var snapshot: AppSnapshot?
}

do {
    let outcome = try Driver().run(command)
    if json { emit(outcome) } else { print(outcome.text) }
} catch {
    var snapshot: AppSnapshot?
    if case UIError.timedOut(_, let taken) = error { snapshot = taken }
    if json {
        emit(Failure(error: String(describing: error), snapshot: snapshot))
    } else {
        FileHandle.standardError.write(Data("hobo-ui: \(error)\n".utf8))
        if let snapshot { print(snapshot.text) }
    }
    exit(1)
}
