import Foundation
import Testing
@testable import HoboAppModel
@testable import HoboCore

@Suite struct HoboInstallTests {
    @Test func insideTheAppVMProcessesRunTheHelperCLI() {
        let gui = URL(filePath: "/Applications/Hobo.app/Contents/MacOS/Hobo")
        let cli = URL(filePath: "/Applications/Hobo.app/Contents/Helpers/hobo")
        #expect(HoboInstall.contents(of: gui)?.path == "/Applications/Hobo.app/Contents")
        #expect(HoboInstall.contents(of: cli)?.path == "/Applications/Hobo.app/Contents")
        #expect(HoboInstall.cli(for: gui) == cli)
        #expect(HoboInstall.cli(for: cli) == cli)
    }

    @Test func aBareBuildRunsTheHoboBesideIt() {
        let gui = URL(filePath: "/src/hobo/.build/debug/HoboApp")
        #expect(HoboInstall.contents(of: gui) == nil)
        #expect(HoboInstall.cli(for: gui).path == "/src/hobo/.build/debug/hobo")
        // A folder that happens to be called MacOS isn't an app.
        #expect(HoboInstall.contents(of: URL(filePath: "/tmp/MacOS/hobo")) == nil)
    }

    @Test func theCommandLineToolIsALinkToTheAppsCLI() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appending(path: "bin/hobo")
        let tool = CommandLineTool(link: link, target: URL(filePath: "/Applications/Hobo.app/Contents/Helpers/hobo"))
        #expect(tool.state == .missing)
        // The command the administrator prompt runs, here without one.
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", tool.command]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
        #expect(tool.state == .installed)
        let other = CommandLineTool(link: link, target: URL(filePath: "/elsewhere/hobo"))
        #expect(other.state == .linkedElsewhere("/Applications/Hobo.app/Contents/Helpers/hobo"))
    }

    @Test func cancellingThePasswordPromptIsNotAFailure() {
        let tool = CommandLineTool(link: URL(filePath: "/usr/local/bin/hobo"), target: URL(filePath: "/elsewhere/hobo"))
        #expect(tool.failure("0:150: execution error: User canceled. (-128)\n") is CancellationError)
        let refused = tool.failure("0:150: execution error: ln: /usr/local/bin/hobo: Operation not permitted (1)\n")
        #expect("\(refused)" == "0:150: execution error: ln: /usr/local/bin/hobo: Operation not permitted (1)")
        #expect("\(tool.failure(""))" == "couldn't link /usr/local/bin/hobo")
    }

    @Test func appleScriptStringsEscapeQuotesAndBackslashes() {
        #expect(CommandLineTool.appleScriptString(#"ln -s '/a "b"\c'"#) == #""ln -s '/a \"b\"\\c'""#)
    }
}
