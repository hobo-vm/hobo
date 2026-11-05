import Foundation
import Testing
@testable import HoboVM

/// `exec --gui`'s shell line, with the guest's `stat`, `launchctl`, `sudo` and `sleep` stubbed by
/// PATH. On a real guest the session is up by the time a test could ask, so waiting for it is only
/// reachable here. Needs no VM.
@Suite struct GUIExecScriptTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "hobo-gui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    private var me: String { NSUserName() }

    private func stub(_ name: String, _ body: String) throws {
        let file = directory.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// Stubs for a guest whose console and session are as given; `sudo` prints its arguments one per line.
    private func guest(console: String, session: Bool = true) throws {
        try stub("stat", "echo \(console)")
        try stub("launchctl", session ? "exit 0" : "exit 113")
        try stub("sleep", "echo slept >> '\(directory.appending(path: "slept").path)'")
        try stub("sudo", #"printf '%s\n' "$@""#)
    }

    private func run(_ command: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", try #require(MacVMBundle.guiExecScript(command))]
        process.environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    private var sleeps: Int {
        let text = (try? String(contentsOf: directory.appending(path: "slept"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    @Test func entersTheSessionAsTheUserKeepingPathAndArguments() throws {
        defer { cleanUp() }
        try guest(console: me)
        let result = try run(["echo", "a b", "$HOME", "it's"])
        #expect(result.status == 0)
        #expect(sleeps == 0, "the session was already up")
        #expect(result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == [
            "-n", "launchctl", "asuser", String(getuid()), "sudo", "-n", "-u", me, "env",
            "PATH=\(directory.path):/usr/bin:/bin", "echo", "a b", "$HOME", "it's", "",
        ])
    }

    @Test func givesUpWithAStatusOfItsOwnWhenNobodyLogsIn() throws {
        defer { cleanUp() }
        try guest(console: "root")
        let result = try run(["true"])
        #expect(result.status == MacVMBundle.guiSessionUnavailableStatus)
        #expect(result.stdout.isEmpty, "never ran the command")
        #expect(result.stderr.contains("desktop session isn't up"))
        #expect(sleeps == MacVMBundle.guiSessionWaitSeconds - 1)
    }

    /// The console can be the user's before launchd has their GUI domain.
    @Test func waitsForTheDomainToo() throws {
        defer { cleanUp() }
        try guest(console: me, session: false)
        let result = try run(["true"])
        #expect(result.status == MacVMBundle.guiSessionUnavailableStatus)
    }

    @Test func aLoginPartWayThroughTheWaitRunsTheCommand() throws {
        defer { cleanUp() }
        try guest(console: me)
        let countFile = directory.appending(path: "slept").path
        // The console turns over after the third sleep.
        try stub("stat", "if [ \"$(wc -l < '\(countFile)' 2>/dev/null || echo 0)\" -ge 3 ]; then echo \(me); else echo root; fi")
        let result = try run(["true"])
        #expect(result.status == 0)
        #expect(sleeps == 3)
        #expect(result.stdout.contains("asuser"))
    }

    @Test func linuxHasNoDesktopSessionYet() {
        #expect(LinuxVMBundle.guiExecScript(["true"]) == nil)
    }
}
