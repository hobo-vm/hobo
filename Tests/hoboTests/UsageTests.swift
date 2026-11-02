import ArgumentParser
import Testing
@testable import hobo

struct UsageTests {
    @Test func listsEveryVisibleCommandOnce() {
        let usageLines = Usage.text(columns: 100).split(separator: "\n").filter { $0.hasPrefix("USAGE: hobo ") }
        let commands = Usage.visibleSubcommands(of: HoboCommand.self)
        #expect(commands.count == HoboCommand.configuration.subcommands.count)
        for command in commands {
            let prefix = "USAGE: hobo \(command._commandName)"
            let matches = usageLines.filter { $0 == prefix || $0.hasPrefix(prefix + " ") }
            #expect(matches.count == 1, "\(prefix)")
        }
    }

    /// The real tree has no hidden or nested commands yet, so a fixture tree pins the filter and order.
    @Test func walksNestedCommandsDepthFirstSkippingHidden() {
        let names = Usage.visibleSubcommands(of: Fixture.self).map { $0._commandName }
        #expect(names == ["first", "save", "restore", "last"])
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
