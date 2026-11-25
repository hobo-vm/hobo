import ArgumentParser
import CLIOutput
import Foundation
import HoboControl
import HoboCore
import HoboUICore

/// `hobo ui <vm> <command> …`: checks the command here, with `HoboUI`'s definitions, then runs it
/// in the guest as hobo-ui, which parses the same arguments with the same definitions.
struct UICommand: AsyncParsableCommand, JSONPassthrough {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Drive a guest's apps: snapshot, at, click, drag, scroll, type, key, menu, choose, wait.",
        discussion: HoboUI.configuration.discussion + " " + """
            A macOS VM needs a recipe with [gui_testing]; Linux desktop and Windows VMs need nothing more. Commands: \(Self.commandList). \
            hobo ui <vm> <command> --help describes one. With --json a command prints JSON, failures included. \
            A command that fails is also recorded, with what it printed, in ~/.hobo/ui-failures.log, for a script that discarded its output.
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
    /// none; nil when the arguments don't ask for help. After `--` nothing is an option, so
    /// `type -- --help` types that text.
    static func helpSubject(of arguments: [String]) -> (any ParsableCommand.Type)? {
        let viaHelp = arguments.first == "help"
        let options = arguments.prefix { $0 != "--" }
        guard viaHelp || options.contains("--help") || options.contains("-h") else { return nil }
        let named = viaHelp ? arguments.dropFirst().first : arguments.first
        return HoboUI.configuration.subcommands.first { $0._commandName == named } ?? HoboUI.self
    }

    /// The command that `hobo ui <command> --help` or `hobo ui help <command>` asks about, with
    /// no VM named: ArgumentParser takes the command for the VM and prints `hobo ui`'s own help,
    /// so `Entry` asks this first. Nil for anything else, `hobo ui key click --help` included:
    /// that is about `click`, in a VM called key.
    static func helpSubjectWithoutVM(of arguments: [String]) -> (any ParsableCommand.Type)? {
        guard let subject = helpSubject(of: arguments), subject != HoboUI.self else { return nil }
        let commands = HoboUI.configuration.subcommands.map { $0._commandName }
        if arguments.first != "help", let second = arguments.dropFirst().first, commands.contains(second) { return nil }
        return subject
    }

    func validate() throws {
        // Help is the host's to print: hobo-ui would print the same.
        if let subject = Self.helpSubject(of: arguments) {
            print(HoboUI.helpMessage(for: subject))
            throw ExitCode.success
        }
        try Self.validate(vm: name, arguments: arguments, failures: UIFailureLog(file: HoboHome.standard().uiFailures))
    }

    /// Throws for arguments hobo-ui wouldn't take, having recorded the usage error in `failures`
    /// as `GuestChannel.ui` records a command that reached the VM and failed there: this one
    /// fails before any VM is asked, and is as lost to a script that discards its output.
    static func validate(vm: String, arguments: [String], failures: UIFailureLog) throws {
        guard let usageError = usageError(of: arguments) else { return }
        let result = "exit \(ExitCode.validationFailure.rawValue)"
        try? failures.record(vm: vm, arguments: arguments, result: result, output: Data(usageError.message.utf8))
        guard usageError.hasUsage else { throw ValidationError(String(usageError.message.dropFirst("Error: ".count))) }
        FileHandle.standardError.write(Data((usageError.message + "\n").utf8))
        throw ExitCode.validationFailure
    }

    /// What is wrong with a command's arguments, as it is printed: nil when hobo-ui would take
    /// them. `hasUsage` is false for no command at all, which ArgumentParser prints with
    /// `hobo ui`'s usage.
    static func usageError(of arguments: [String]) -> (message: String, hasUsage: Bool)? {
        guard !arguments.isEmpty else { return ("Error: give a command: \(commandList)", false) }
        do {
            _ = try HoboUI.parseAsRoot(arguments)
            return nil
        } catch {
            // With the usage of the command that failed (`hobo ui <vm> key <cmd+k>`), not of `hobo ui`.
            var message = HoboUI.usageError(for: error)
            if let hint = HoboUI.scrollHint(for: arguments) ?? HoboUI.refOptionHint(for: arguments) ?? HoboUI.atAppHint(for: arguments), let usage = message.range(of: "Usage:") {
                message = "Error: \(hint)\n" + message[usage.lowerBound...]
            }
            return (message, true)
        }
    }

    func run() async throws {
        let json = arguments.contains("--json")
        do {
            let status = try GuestChannel().ui(name, arguments: arguments, onOutput: writeOutput)
            if status != 0 { throw ExitCode(status) }
        } catch let error where json && !(error is ExitCode) {
            // hobo-ui prints its own failures as JSON; this is for the host's (a VM not running).
            let message = String(describing: error)
            let data = (try? CLIJSON.document(["error": message])) ?? Data()
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            throw ExitCode.failure
        }
    }
}
