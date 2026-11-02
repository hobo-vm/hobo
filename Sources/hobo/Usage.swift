import ArgumentParser
import HoboCore

/// `hobo usage`: the whole reference in one read, for an agent (or a person) learning hobo. It is
/// every visible command's `--help`, generated from the same configurations so it can't drift,
/// followed by the conventions that cut across commands and would otherwise repeat in each one.
struct Usage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the full reference: every command's help, then the conventions they share.",
        discussion: "Read this once instead of running --help on each command."
    )

    func run() {
        print(Self.text())
    }

    static func text(columns: Int? = nil) -> String {
        let commands = visibleSubcommands(of: HoboCommand.self)
        let sections = [HoboCommand.helpMessage(columns: columns)]
            + commands.map { HoboCommand.helpMessage(for: $0, columns: columns) }
            + [conventions]
        return sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n" + String(repeating: "─", count: 40) + "\n\n")
    }

    /// Depth-first, in declaration order, so nested commands (`snapshot save`) follow their parent.
    static func visibleSubcommands(of command: ParsableCommand.Type) -> [ParsableCommand.Type] {
        command.configuration.subcommands
            .filter { $0.configuration.shouldDisplay }
            .flatMap { [$0] + visibleSubcommands(of: $0) }
    }

    /// Which visible commands lack `--json` and which stream JSON Lines, read from each command's
    /// `OutputCommand` conformance and `jsonStyle` rather than listed by hand.
    static func jsonSupport(of root: ParsableCommand.Type) -> (withoutJSON: [String], events: [String]) {
        var withoutJSON: [String] = []
        var events: [String] = []
        for command in visibleSubcommands(of: root) {
            guard let outputCommand = command as? any OutputCommand.Type else {
                withoutJSON.append(command._commandName)
                continue
            }
            if outputCommand.jsonStyle == .events { events.append(command._commandName) }
        }
        return (withoutJSON, events)
    }

    static var conventions: String {
        let json = jsonSupport(of: HoboCommand.self)
        return """
            CONVENTIONS:
              VMs         Each VM is a bundle, ~/Hobo/<name>.hobovm (HOBO_VMS overrides the directory).
                          `hobo list` shows every VM and its state.
              Recipes     `create` builds from a \(Recipe.fileName) recipe, ./\(Recipe.fileName) by default.
                          `hobo init` writes a starter and `hobo validate` checks one.
              Guest user  `exec`, `cp` and `ssh` act as the \(Conventions.username) user over SSH
                          (password \(Conventions.password), passwordless sudo).
              JSON        Every command takes --json except \(codeList(json.withoutJSON)).
                          Quick commands print one JSON document. These print JSON Lines instead,
                          {"event":"log","message":…} as they go, then {"event":"result","result":…}:
                          \(codeList(json.events)).
                          Sizes are bytes, dates ISO 8601.
              Errors      A failure prints {"error":…} (or an error event) on stdout under --json, and hobo
                          exits 1. Usage errors are text on stderr.
              exec, cp    hobo exits with the guest command's (or scp's) status. With --json their output
                          goes to stderr and stdout gets {"exitStatus":…}.
              Capacity    macOS allows at most 2 running macOS guests per host.
            """
    }

    private static func codeList(_ names: [String]) -> String {
        names.map { "`\($0)`" }.joined(separator: ", ")
    }
}
