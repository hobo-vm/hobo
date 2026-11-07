import Foundation
import Testing
@testable import HoboVM

/// The Linux `exec --gui` script, with the guest's `systemctl`, `loginctl` and `sleep` stubbed by
/// PATH, run by bash as on the guest. Needs no VM.
@Suite struct LinuxGUIExecScriptTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "hobo-linux-gui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    private var slept: String { directory.appending(path: "slept").path }

    /// What GNOME gives the user manager on Ubuntu 26.04, as `systemctl` quotes it.
    static let desktopEnvironment = """
        PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin
        WAYLAND_DISPLAY=wayland-0
        DISPLAY=:0
        XDG_SESSION_TYPE=wayland
        QT_IM_MODULES=$'wayland;ibus'
        """

    private func stub(_ name: String, _ body: String) throws {
        let file = directory.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// Stubs for a guest with or without a display manager, whose desktop session and user
    /// environment are as given. `session` and `environment` are shell snippets that print them.
    private func guest(
        displayManager: Bool = true, session: String = "echo 4", environment: String = "cat <<'X'\n\(desktopEnvironment)\nX"
    ) throws {
        try stub("systemctl", """
            if [ "$1" = is-enabled ]; then exit \(displayManager ? 0 : 1); fi
            \(environment)
            """)
        try stub("loginctl", session)
        try stub("sleep", "echo slept >> '\(slept)'")
    }

    private func run(_ command: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", LinuxVMBundle.guiExecScript(command)]
        process.environment = ["PATH": "\(directory.path):/usr/bin:/bin", "XDG_SESSION_TYPE": "tty", "XDG_SESSION_ID": "18"]
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
        let text = (try? String(contentsOf: URL(filePath: slept), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    @Test func runsWithTheDesktopsEnvironmentButSSHsPath() throws {
        defer { cleanUp() }
        try guest()
        let result = try run([
            "sh", "-c", #"printf '%s\n' "$PATH" "$WAYLAND_DISPLAY" "$DISPLAY" "$XDG_SESSION_TYPE" "$XDG_SESSION_ID" "$QT_IM_MODULES" "$1""#,
            "sh", "it's a b",
        ])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(sleeps == 0, "the session was already up")
        #expect(result.stdout.split(separator: "\n").map(String.init) == [
            "\(directory.path):/usr/bin:/bin", "wayland-0", ":0", "wayland", "4", "wayland;ibus", "it's a b",
        ])
    }

    @Test func passesTheCommandsExitStatusThrough() throws {
        defer { cleanUp() }
        try guest()
        #expect(try run(["sh", "-c", "exit 7"]).status == 7)
    }

    /// A `--server` guest will never have a session, so it fails without the wait.
    @Test func aGuestWithNoDisplayManagerFailsAtOnce() throws {
        defer { cleanUp() }
        try guest(displayManager: false)
        let result = try run(["true"])
        #expect(result.status == GUISession.unavailableStatus)
        #expect(result.stderr.contains("no desktop"))
        #expect(sleeps == 0)
    }

    @Test func givesUpWhenNobodyLogsIn() throws {
        defer { cleanUp() }
        try guest(session: "echo")
        let result = try run(["echo", "ran"])
        #expect(result.status == GUISession.unavailableStatus)
        #expect(result.stdout.isEmpty, "never ran the command")
        #expect(result.stderr.contains("desktop session isn't up"))
        #expect(sleeps == GUISession.waitSeconds - 1)
    }

    /// loginctl can name the session before GNOME has handed the user manager its display.
    @Test func waitsForTheDisplayInTheUserEnvironmentToo() throws {
        defer { cleanUp() }
        try guest(environment: "echo PATH=/usr/bin")
        #expect(try run(["true"]).status == GUISession.unavailableStatus)
    }

    @Test func aLoginPartWayThroughTheWaitRunsTheCommand() throws {
        defer { cleanUp() }
        // The session appears after the third sleep.
        try guest(session: "if [ \"$(wc -l < '\(slept)' 2>/dev/null || echo 0)\" -ge 3 ]; then echo 4; else echo; fi")
        let result = try run(["echo", "ran"])
        #expect(result.status == 0)
        #expect(sleeps == 3)
        #expect(result.stdout == "ran\n")
    }
}
