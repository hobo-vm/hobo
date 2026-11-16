import ArgumentParser
import HoboCore
import HoboUICore

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
        let commands = visibleCommandPaths(of: HoboCommand.self).map(\.command)
        // `hobo ui`'s own commands are parsed by hobo-ui's definitions, not as subcommands.
        let uiCommands = HoboUI.configuration.subcommands.map { HoboUI.helpMessage(for: $0, columns: columns) }
        let sections = [HoboCommand.helpMessage(columns: columns)]
            + commands.flatMap { command in
                [HoboCommand.helpMessage(for: command, columns: columns)] + (command == UICommand.self ? uiCommands : [])
            }
            + [conventions]
        return sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n" + String(repeating: "─", count: 40) + "\n\n")
    }

    /// Each visible command with its name as typed after the root (`claude install`). Depth-first,
    /// in declaration order, so nested commands follow their parent.
    static func visibleCommandPaths(of command: ParsableCommand.Type, prefix: String = "")
        -> [(path: String, command: ParsableCommand.Type)] {
        command.configuration.subcommands
            .filter { $0.configuration.shouldDisplay }
            .flatMap { sub in
                let path = prefix + sub._commandName
                return [(path, sub)] + visibleCommandPaths(of: sub, prefix: path + " ")
            }
    }

    /// Which visible commands lack `--json` and which stream JSON Lines, read from each command's
    /// `OutputCommand` conformance and `jsonStyle` rather than listed by hand. A group (`claude`)
    /// only holds subcommands, so it's in neither list.
    static func jsonSupport(of root: ParsableCommand.Type) -> (withoutJSON: [String], events: [String]) {
        var withoutJSON: [String] = []
        var events: [String] = []
        for (path, command) in visibleCommandPaths(of: root) {
            guard let outputCommand = command as? any OutputCommand.Type else {
                if command.configuration.subcommands.isEmpty && !(command is any JSONPassthrough.Type) { withoutJSON.append(path) }
                continue
            }
            if outputCommand.jsonStyle == .events { events.append(path) }
        }
        return (withoutJSON, events)
    }

    static var conventions: String {
        let json = jsonSupport(of: HoboCommand.self)
        return """
            CONVENTIONS:
              VMs         Each VM is a bundle, ~/Hobo/<name>.hobovm (HOBO_VMS overrides the directory).
                          `hobo list` shows every VM, its state and its disk use.
              Recipes     `create` builds from a \(Recipe.fileName) recipe, ./\(Recipe.fileName) by default.
                          `hobo init` writes a starter (macOS, Ubuntu with --os linux, or Windows with
                          --os windows <iso>) and `hobo validate` checks one. [source] ipsw makes a macOS
                          guest, image a Linux one, iso a Windows one.
              Guest user  `exec`, `cp`, `rm` and `ssh` act as the \(Conventions.username) user
                          (password \(Conventions.password), passwordless sudo; on Windows an elevated
                          administrator, with PowerShell as the shell).
              JSON        Every command takes --json except \(codeList(json.withoutJSON)).
                          Quick commands print one JSON document. These print JSON Lines instead,
                          {"event":"log","message":…} as they go, then {"event":"result","result":…}:
                          \(codeList(json.events)).
                          Sizes are bytes, dates ISO 8601.
              Errors      A failure prints {"error":…} (or an error event) on stdout under --json, the same
                          message on stderr, and hobo exits 1. Usage errors are text on stderr.
              exec, cp,   hobo exits with the guest command's (or scp's) status. With --json their output
              rm          goes to stderr and stdout gets {"exitStatus":…}. `rm` removes files in a VM,
                          never the VM: that is `delete`.
              screenshot  Prints where the PNG went; --json gives {"name":…,"path":…}. It and exec --gui
                          need a desktop: on macOS a screenshot needs [gui_testing], and a Linux guest
                          built with `init --os linux --server` has none.
              Ephemeral   `start <vm> --ephemeral` boots a new clone of a stopped VM, named <vm>-<4 hex>
                          (printed, and result.name in the --json result event). An ephemeral VM is deleted
                          when it stops, even by crashing, but not when it is suspended. `set <name> --keep`
                          keeps it.
                          It also stops itself after \(IdleTimeout.standard) idle (`start --idle-timeout`, or off), shown by
                          `list`. A hobo command on it resets the clock, except `list`; raw SSH doesn't. A VM
                          not found mid-session has probably expired: start another.
              Snapshots   `snapshot save <vm> <tag>` on a running or suspended VM also saves its memory, and
                          `snapshot restore` returns to that running moment; a stopped VM's has only its
                          disk, and it stays stopped. Restoring over a running or suspended VM takes
                          --force. Ephemeral VMs can't have snapshots.
              Capacity    macOS allows at most 2 running macOS guests per host.
            """
    }

    private static func codeList(_ names: [String]) -> String {
        names.map { "`\($0)`" }.joined(separator: ", ")
    }
}
