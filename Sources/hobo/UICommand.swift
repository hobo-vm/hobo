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

    /// The command a request for help is about (`key --help`, `help key`), `HoboUI` when it names
    /// none; nil when the arguments don't ask for help.
    static func helpSubject(of arguments: [String]) -> (any ParsableCommand.Type)? {
        let viaHelp = arguments.first == "help"
        guard viaHelp || arguments.contains("--help") || arguments.contains("-h") else { return nil }
        let named = viaHelp ? arguments.dropFirst().first : arguments.first
        return HoboUI.configuration.subcommands.first { $0._commandName == named } ?? HoboUI.self
    }

    func validate() throws {
        guard !arguments.isEmpty else { throw ValidationError("give a command: \(Self.commandList)") }
        // Help is the host's to print: hobo-ui would print the same.
        if let subject = Self.helpSubject(of: arguments) {
            print(HoboUI.helpMessage(for: subject))
            throw ExitCode.success
        }
        do {
            _ = try HoboUI.parseAsRoot(arguments)
        } catch {
            // With the usage of the command that failed (`hobo ui <vm> key <cmd+k>`), not of `hobo ui`.
            FileHandle.standardError.write(Data((HoboUI.fullMessage(for: error) + "\n").utf8))
            throw ExitCode.validationFailure
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
