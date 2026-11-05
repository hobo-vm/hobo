import Foundation
import Testing
@testable import HoboCore

@Suite struct GuestScreenshotTests {
    let directory: URL
    let screenshot = GuestScreenshot(name: "dev", png: Data("png".utf8))
    /// 2027-01-15 08:00:07 UTC, in whatever zone the host is.
    let date = Date(timeIntervalSince1970: 1_800_000_007)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "hobo-shot-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    private var stamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    @Test func aDefaultNameNeverReplacesAnEarlierShot() throws {
        defer { cleanUp() }
        let first = try screenshot.save(to: nil, in: directory, date: date)
        let second = try GuestScreenshot(name: "dev", png: Data("two".utf8)).save(to: nil, in: directory, date: date)
        let third = try screenshot.save(to: nil, in: directory, date: date)
        #expect(first.lastPathComponent == "dev-\(stamp).png")
        #expect(second.lastPathComponent == "dev-\(stamp)-2.png")
        #expect(third.lastPathComponent == "dev-\(stamp)-3.png")
        #expect(try Data(contentsOf: first) == Data("png".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    @Test func aNamedPathIsRelativeToTheDirectoryAndReplaced() throws {
        defer { cleanUp() }
        let file = directory.appending(path: "shot.png")
        try Data("old".utf8).write(to: file)
        #expect(try screenshot.save(to: "shot.png", in: directory, date: date).path == file.path)
        #expect(try Data(contentsOf: file) == Data("png".utf8))
    }

    /// The path is printed for the caller to use, so it comes back without the `..`.
    @Test func anAbsolutePathIgnoresTheDirectory() throws {
        defer { cleanUp() }
        let file = directory.appending(path: "shot.png")
        let saved = try screenshot.save(to: directory.path + "/elsewhere/../shot.png", in: directory.appending(path: "unused"), date: date)
        #expect(saved.path == file.path)
        #expect(try Data(contentsOf: file) == Data("png".utf8))
    }

    @Test func aFailedWriteIsAnErrorRatherThanALoop() throws {
        defer { cleanUp() }
        let missing = directory.appending(path: "missing")
        #expect(throws: (any Error).self) { try screenshot.save(to: nil, in: missing, date: date) }
    }

    @Test func resultShape() throws {
        let json = String(decoding: try HoboJSON.line(ScreenshotResult(name: "dev", path: "/tmp/a.png")), as: UTF8.self)
        #expect(json == #"{"name":"dev","path":"/tmp/a.png"}"#)
    }

    // The capture script, with the guest's tools stubbed by PATH. The integration test covers it on
    // a real guest, but only with the grant: its refusal would take a VM built without one.

    /// Runs the script with `osascript` answering `granted`, and a `screencapture` that notes the
    /// file it was given, in `tempFile`, then runs `screencapture`, where `$last` is that file.
    private func capture(
        granted: String, screencapture: String = #"printf shot > "$last""#
    ) throws -> (status: Int32, stdout: Data, stderr: String, tempFile: String?) {
        let note = directory.appending(path: "captured")
        try stub("osascript", "echo \(granted)")
        try stub("screencapture", "for last; do :; done; printf %s \"$last\" > '\(note.path)'; \(screencapture)")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/\(GuestScreenshot.command[0])")
        process.arguments = Array(GuestScreenshot.command.dropFirst())
        process.environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, String(decoding: stderr, as: UTF8.self), try? String(contentsOf: note, encoding: .utf8))
    }

    private func stub(_ name: String, _ body: String) throws {
        let file = directory.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    @Test func theCaptureGoesToStdoutWithTheGrant() throws {
        defer { cleanUp() }
        let result = try capture(granted: "true")
        #expect(result.status == 0)
        #expect(result.stdout == Data("shot".utf8))
        #expect(result.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(result.tempFile)))
    }

    /// Exiting 0 with no output would blame the capture for coming back empty, not for failing.
    @Test func aFailedCaptureKeepsItsStatusAndLeavesNothing() throws {
        defer { cleanUp() }
        let result = try capture(granted: "true", screencapture: "exit 3")
        #expect(result.status == 3)
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(result.tempFile)))
    }

    /// A cancelled exec signals the script, which exits as a command killed by SIGTERM would.
    @Test func anInterruptedCaptureLeavesNothing() throws {
        defer { cleanUp() }
        let result = try capture(granted: "true", screencapture: "kill -TERM $PPID")
        #expect(result.status == 143)
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(result.tempFile)))
    }

    /// `screencapture` would succeed, leaving windows out.
    @Test func withoutTheGrantItFailsAndNeverCaptures() throws {
        defer { cleanUp() }
        let result = try capture(granted: "false")
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("[gui_testing]"))
        #expect(result.tempFile == nil)
    }
}
