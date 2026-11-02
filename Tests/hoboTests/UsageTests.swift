import ArgumentParser
import Testing
@testable import hobo

struct UsageTests {
    @Test func listsEveryVisibleCommandOnce() {
        let usageLines = Usage.text(columns: 100).split(separator: "\n").filter { $0.hasPrefix("USAGE: hobo ") }
        let paths = Usage.visibleCommandPaths(of: HoboCommand.self).map(\.path)
        #expect(paths.contains("claude install"))
        for path in paths {
            // A group's own line is `hobo claude <subcommand>`; its subcommands' lines are theirs.
            let prefix = "USAGE: hobo \(path)"
            let others = paths.filter { $0.hasPrefix(path + " ") }.map { "USAGE: hobo \($0)" }
            let matches = usageLines.filter { line in
                (line == prefix || line.hasPrefix(prefix + " "))
                    && !others.contains { line == $0 || line.hasPrefix($0 + " ") }
            }
            #expect(matches.count == 1, "\(prefix)")
        }
    }

    /// The real tree has no hidden commands, so a fixture tree pins the filter and order.
    @Test func walksNestedCommandsDepthFirstSkippingHidden() {
        let paths = Usage.visibleCommandPaths(of: Fixture.self).map(\.path)
        #expect(paths == ["first", "first save", "first restore", "last"])
    }

    @Test func readsJSONSupportFromEachCommand() {
        let json = Usage.jsonSupport(of: JSONFixture.self)
        #expect(json.withoutJSON == ["plain"])
        #expect(json.events == ["group streamed"])
    }

    @Test func endsWithTheConventions() {
        #expect(Usage.text(columns: 100).hasSuffix(Usage.conventions.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

private struct Fixture: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [First.self, Hidden.self, Last.self])

    struct First: ParsableCommand {
        static let configuration = CommandConfiguration(subcommands: [Save.self, Secret.self, Restore.self])
    }

    struct Save: ParsableCommand {}
    struct Restore: ParsableCommand {}
    struct Last: ParsableCommand {}

    struct Hidden: ParsableCommand {
        static let configuration = CommandConfiguration(shouldDisplay: false, subcommands: [Save.self])
    }

    struct Secret: ParsableCommand {
        static let configuration = CommandConfiguration(shouldDisplay: false)
    }
}

private struct JSONFixture: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Plain.self, Quick.self, Group.self])

    /// Holds subcommands and has no `--json` of its own, so it's in neither list.
    struct Group: ParsableCommand {
        static let configuration = CommandConfiguration(subcommands: [Streamed.self])
    }

    struct Plain: ParsableCommand {}

    struct Quick: OutputCommand {
        var json = false
        static let jsonStyle = Output.JSONStyle.document
        func execute(_ output: Output) async throws -> Reply { Reply(0, text: nil) }
    }

    struct Streamed: OutputCommand {
        var json = false
        static let jsonStyle = Output.JSONStyle.events
        func execute(_ output: Output) async throws -> Reply { Reply(0, text: nil) }
    }
}

struct InitOptionTests {
    @Test func serverIsOnlyForLinux() throws {
        #expect(throws: (any Error).self) { try Init.parse(["--server"]) }
        _ = try Init.parse(["--os", "linux", "--server"])
    }
}
