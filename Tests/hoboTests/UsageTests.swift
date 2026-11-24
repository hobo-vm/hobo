import ArgumentParser
import CLIOutput
import Foundation
import HoboCore
import HoboUICore
import Testing
@testable import hobo

struct UsageTests {
    @Test func uiHelpIsAboutTheCommandNamed() {
        #expect(UICommand.helpSubject(of: ["key", "--help"]) == HoboUI.Key.self)
        #expect(UICommand.helpSubject(of: ["help", "key"]) == HoboUI.Key.self)
        #expect(UICommand.helpSubject(of: ["click", "e1", "-h"]) == HoboUI.Click.self)
        #expect(UICommand.helpSubject(of: ["help"]) == HoboUI.self)
        #expect(UICommand.helpSubject(of: ["--help"]) == HoboUI.self)
        #expect(UICommand.helpSubject(of: ["key", "cmd+a"]) == nil)
        #expect(UICommand.helpSubject(of: ["type", "--", "--help"]) == nil)
        #expect(UICommand.helpSubject(of: ["type", "--help", "--", "x"]) == HoboUI.TypeText.self)
    }

    @Test func listsEveryVisibleCommandOnce() {
        let allLines = Usage.text(columns: 100).split(separator: "\n").filter { $0.hasPrefix("USAGE: hobo ") }
        // `hobo ui`'s own commands, parsed by hobo-ui's definitions, follow its help.
        let uiLines = allLines.filter { $0.hasPrefix("USAGE: hobo ui <vm> ") }
        for name in HoboUI.configuration.subcommands.map({ $0._commandName }) {
            #expect(uiLines.filter { $0.hasPrefix("USAGE: hobo ui <vm> \(name) ") }.count == 1, "\(name)")
        }
        let usageLines = allLines.filter { !$0.hasPrefix("USAGE: hobo ui <vm> ") }
        let paths = CommandTree.visibleCommandPaths(of: HoboCommand.self).map(\.path)
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

    /// All of it is too long for one tool result, so an agent asks for the commands it will use.
    @Test func namingCommandsPrintsOnlyTheirsAndTheConventions() throws {
        let text = Usage.text(of: ["snapshot", "ui"], columns: 100)
        let usageLines = text.split(separator: "\n").filter { $0.hasPrefix("USAGE: hobo ") }
        let expected = ["ui <name> ", "ui <vm> snapshot ", "ui <vm> key ", "snapshot <subcommand>", "snapshot save ", "snapshot restore "]
        for prefix in expected {
            #expect(usageLines.filter { $0.hasPrefix("USAGE: hobo " + prefix) }.count == 1, "\(prefix)")
        }
        #expect(usageLines.allSatisfy { $0.hasPrefix("USAGE: hobo ui ") || $0.hasPrefix("USAGE: hobo snapshot ") })
        #expect(text.hasSuffix(Usage.conventions.trimmingCharacters(in: .whitespacesAndNewlines)))
        // What the skill's example asks for fits in one tool result.
        #expect(Usage.text(of: ["start", "exec", "cp", "ui", "screenshot"], columns: 80).utf8.count < 25_000)
        #expect(Usage.text(columns: 100).contains(text.components(separatedBy: "\n\n").first!))
    }

    @Test func namingACommandHoboHasntGotIsAUsageError() throws {
        #expect(try Usage.parse([]).commands.isEmpty)
        #expect(try Usage.parse(["ui", "claude"]).commands == ["ui", "claude"])
        #expect(throws: (any Error).self) { try Usage.parse(["uii"]) }
        // A subcommand comes with its command.
        #expect(throws: (any Error).self) { try Usage.parse(["save"]) }
        #expect(Usage.topLevelCommands.contains("usage") && !Usage.topLevelCommands.contains { $0.hasPrefix("_") })
    }

    @Test func endsWithTheConventions() {
        #expect(Usage.text(columns: 100).hasSuffix(Usage.conventions.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

struct InitOptionTests {
    @Test func serverIsOnlyForLinux() throws {
        #expect(throws: (any Error).self) { try Init.parse(["--server"]) }
        _ = try Init.parse(["--os", "linux", "--server"])
    }

    @Test func outputNamesTheRecipeFile() throws {
        #expect(try Init.parse([]).recipeFile == "Hobo.toml")
        #expect(try Init.parse(["--os", "linux", "-o", "linux.toml"]).recipeFile == "linux.toml")
        #expect(try Init.parse(["26B123", "--output", "macos.toml"]).recipeFile == "macos.toml")
    }

    /// An unpinned macOS recipe needs no catalog, so this runs offline.
    @Test func writesTheNamedRecipeAndKeepsAnExistingOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recipe = dir.appending(path: "macos.toml")
        let output = Output(json: false, style: Init.jsonStyle)

        let reply = try await Init.parse(["-o", recipe.path]).execute(output)
        #expect(reply.text == "Wrote \(recipe.path)")
        #expect(try String(contentsOf: recipe, encoding: .utf8) == Recipe.template)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Hobo.toml").path))

        try "kept".write(to: recipe, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await Init.parse(["-o", recipe.path]).execute(output) }
        #expect(try String(contentsOf: recipe, encoding: .utf8) == "kept")
        _ = try await Init.parse(["-o", recipe.path, "--force"]).execute(output)
        #expect(try String(contentsOf: recipe, encoding: .utf8) == Recipe.template)
    }

    @Test func outputIsNotADirectory() throws {
        #expect(throws: (any Error).self) { try Init.parse(["-o", "."]) }
        #expect(throws: (any Error).self) { try Init.parse(["-o", "recipes/"]) }
        #expect(throws: (any Error).self) { try Init.parse(["-o", ""]) }
        #expect(throws: (any Error).self) { try Init.parse(["-o", NSTemporaryDirectory(), "--force"]) }
    }
}

struct IdleTimeoutOptionTests {
    /// A typo mustn't reach the VM process, whose missing option would mean the standard timeout.
    @Test func startRefusesATypo() throws {
        #expect(try Start.parse(["dev", "--ephemeral"]).idleTimeout == nil)
        #expect(try Start.parse(["dev", "--ephemeral", "--idle-timeout", "off"]).idleTimeout == .off)
        #expect(try Start.parse(["dev", "--ephemeral", "--idle-timeout", "90s"]).idleTimeout == .after(seconds: 90))
        #expect(throws: (any Error).self) { try Start.parse(["dev", "--ephemeral", "--idle-timeout", "30"]) }
    }

    @Test func theVMProcessReadsTheOptionItIsGiven() throws {
        #expect(try VMRun.parse(["dev"]).idleTimeout == nil)
        #expect(try VMRun.parse(["dev", "--idle-timeout", "off"]).idleTimeout == .off)
        #expect(try VMRun.parse(["dev", "--idle-timeout", "90s"]).idleTimeout == .after(seconds: 90))
    }
}

struct DeleteOptionTests {
    @Test func jsonNeedsSomethingThatSkipsThePrompt() throws {
        #expect(throws: (any Error).self) { try Delete.parse(["dev", "--json"]) }
        _ = try Delete.parse(["dev", "--json", "--yes"])
        _ = try Delete.parse(["dev", "--json", "--force"])
    }
}

struct ScreenshotOptionTests {
    /// A window partly off the screen's left or top has a frame that starts with "-", which must
    /// not be read as an option.
    @Test func cropTakesAFrameThatStartsOffTheScreen() throws {
        let crop = ScreenshotCrop(x: -40, y: -8, width: 200, height: 100)
        #expect(try Screenshot.parse(["dev", "--crop", "-40,-8,200,100"]).crop == crop)
        #expect(try Screenshot.parse(["dev", "--crop", "-40,-8 200×100", "shot.png"]).crop == crop)
        #expect(throws: (any Error).self) { try Screenshot.parse(["dev", "--crop", "1,2,3"]) }
    }

    @Test func anAppOrARefFindsTheRectangleInsteadOfCrop() throws {
        #expect(try Screenshot.parse(["dev"]).subject == nil)
        #expect(try Screenshot.parse(["dev", "--app", "TextEdit"]).subject == .app("TextEdit"))
        #expect(try Screenshot.parse(["dev", "--ref", "e12"]).subject == .element(ref: "e12", app: nil))
        #expect(try Screenshot.parse(["dev", "--ref", "e12", "--app", "TextEdit", "shot.png"]).subject == .element(ref: "e12", app: "TextEdit"))
        #expect(throws: (any Error).self) { try Screenshot.parse(["dev", "--ref", "12"]) }
        #expect(throws: (any Error).self) { try Screenshot.parse(["dev", "--app", "TextEdit", "--crop", "1,2,3,4"]) }
        #expect(throws: (any Error).self) { try Screenshot.parse(["dev", "--ref", "e12", "--crop", "1,2,3,4"]) }
    }

    /// The JSON would land in the middle of the PNG's stdout.
    @Test func jsonNeedsTheOutputToBeAFile() throws {
        #expect(throws: (any Error).self) { try Screenshot.parse(["dev", "--json", "-o", "-"]) }
        _ = try Screenshot.parse(["dev", "--json"])
        _ = try Screenshot.parse(["dev", "--json", "-o", "shot.png"])
        _ = try Screenshot.parse(["dev", "-o", "-"])
        #expect(throws: (any Error).self) { try Screenshot.parse(["dev", "-", "--json"]) }
        _ = try Screenshot.parse(["dev", "shot.png", "--json"])
        _ = try Screenshot.parse(["dev", "-"])
    }

    @Test func thePathIsTheSecondArgumentOrAnOption() throws {
        #expect(try Screenshot.parse(["dev", "shot.png"]).path == "shot.png")
        #expect(try Screenshot.parse(["dev", "-o", "shot.png"]).outputOption == "shot.png")
        #expect(try Screenshot.parse(["dev", "--output", "shot.png"]).outputOption == "shot.png")
        #expect(throws: (any Error).self) { try Screenshot.parse(["dev", "a.png", "-o", "b.png"]) }
    }
}

struct RemoveOptionTests {
    /// `rm -r` and `rm -rf` are habit; -r has no effect and -f is --force.
    @Test func takesRmsFlags() throws {
        let remove = try Remove.parse(["-rf", "dev:/tmp/app", "dev:b"])
        #expect(remove.force && remove.paths == ["dev:/tmp/app", "dev:b"])
        #expect(try Remove.parse(["dev:a"]).force == false)
    }

    @Test func helpSaysItRemovesFilesNotVMs() {
        #expect(Remove.configuration.abstract.contains("not the VM"))
        #expect(Delete.configuration.abstract.contains("hobo rm"))
    }
}

struct CopyOptionTests {
    /// `cp -r` is habit, so the flag still parses though directories no longer need it.
    @Test func recursiveIsStillAccepted() throws {
        #expect(try Copy.parse(["-r", "build", "dev:/tmp/"]).paths == ["build", "dev:/tmp/"])
        #expect(try Copy.parse(["--recursive", "build", "dev:/tmp/"]).paths == ["build", "dev:/tmp/"])
        #expect(try Copy.parse(["build", "dev:/tmp/"]).paths == ["build", "dev:/tmp/"])
    }

    @Test func replaceIsOffUnlessAsked() throws {
        #expect(try Copy.parse(["build", "dev:/tmp/"]).replace == false)
        #expect(try Copy.parse(["--replace", "build", "dev:/tmp/"]).replace)
    }
}
