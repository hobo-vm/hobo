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

    static let conventions = """
        CONVENTIONS:
          VMs         Each VM is a bundle, ~/Hobo/<name>.hobovm (HOBO_VMS overrides the directory).
                      `hobo list` shows every VM and its state.
          Recipes     `create` builds from a \(Recipe.fileName) recipe, ./\(Recipe.fileName) by default.
                      `hobo init` writes a starter and `hobo validate` checks one.
          Guest user  `exec`, `cp` and `ssh` act as the \(Conventions.username) user over SSH
                      (password \(Conventions.password), passwordless sudo).
          JSON        Every command but `ssh` and `usage` takes --json. Quick commands print one JSON
                      document. `create`, `start` and `stop` print JSON Lines: {"event":"log","message":…}
                      as they go, then {"event":"result","result":…}. Sizes are bytes, dates ISO 8601.
          Errors      A failure prints {"error":…} (or an error event) on stdout under --json, and hobo
                      exits 1. Usage errors are text on stderr.
          exec, cp    hobo exits with the guest command's (or scp's) status. With --json their output
                      goes to stderr and stdout gets {"exitStatus":…}.
          Capacity    macOS allows at most 2 running macOS guests per host.
        """
}
