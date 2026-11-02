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

    @Test func leavesOutHiddenCommands() {
        #expect(!Usage.text(columns: 100).contains("_vm-run"))
    }

    @Test func endsWithTheConventions() {
        #expect(Usage.text(columns: 100).hasSuffix(Usage.conventions.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
