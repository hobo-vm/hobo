import ArgumentParser
import Foundation
import HoboControl
import HoboCore
import HoboUICore

/// `hobo ui <vm> <command> …`: checks the command here, with `HoboUI`'s definitions, then runs it
/// in the guest as hobo-ui, which parses the same arguments with the same definitions.
struct UICommand: AsyncParsableCommand, JSONPassthrough {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Drive a macOS guest's apps: snapshot, click, drag, scroll, type, key, menu, wait.",
        discussion: HoboUI.configuration.discussion + " " + """
            Needs a VM built from a recipe with [gui_testing]. Commands: \(Self.commandList). \
            hobo ui <vm> <command> --help describes one. With --json a command prints JSON, failures included.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Argument(parsing: .captureForPassthrough, help: ArgumentHelp("The command and its arguments, e.g. snapshot --app TextEdit.", valueName: "command"))
    var arguments: [String] = []

    static var commandList: String {
        HoboUI.configuration.subcommands.map { $0._commandName }.joined(separator: ", ")
    }

    func validate() throws {
        guard !arguments.isEmpty else { throw ValidationError("give a command: \(Self.commandList)") }
        // Help is the host's to print: hobo-ui would print the same.
        if arguments.contains("--help") || arguments.contains("-h") || arguments.first == "help" {
            let subcommand = HoboUI.configuration.subcommands.first { $0._commandName == arguments.first }
            print(HoboUI.helpMessage(for: subcommand ?? HoboUI.self))
            throw ExitCode.success
        }
        do {
            _ = try HoboUI.parseAsRoot(arguments)
        } catch {
            throw ValidationError(HoboUI.message(for: error))
        }
    }

    func run() async throws {
        let json = arguments.contains("--json")
        do {
            let status = try GuestChannel().ui(name, arguments: arguments, onOutput: writeOutput)
            if status != 0 { throw ExitCode(status) }
        } catch let error where json && !(error is ExitCode) {
            // hobo-ui prints its own failures as JSON; this is for the host's (a VM not running).
            let data = (try? HoboJSON.document(["error": String(describing: error)])) ?? Data()
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            throw ExitCode.failure
        }
    }
}
