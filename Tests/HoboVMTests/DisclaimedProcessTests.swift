import Foundation
import Testing
@testable import HoboVM

/// Every ssh and scp to a guest goes through `DisclaimedProcess`. Needs no VM, so it runs without
/// HOBO_INTEGRATION.
@Suite struct DisclaimedProcessTests {
    @Test func reportsTheExitStatus() async throws {
        let process = try DisclaimedProcess.spawn("/bin/sh", ["-c", "exit 7"])
        #expect(await process.waitForExit() == 7)
    }

    @Test func reportsAKillingSignalAsAShellDoes() async throws {
        let process = try DisclaimedProcess.spawn("/bin/sh", ["-c", "kill -TERM $$"])
        #expect(await process.waitForExit() == 128 + SIGTERM)
    }

    @Test func terminateStopsTheChild() async throws {
        let process = try DisclaimedProcess.spawn("/bin/sleep", ["60"])
        process.terminate()
        #expect(await process.waitForExit() == 128 + SIGTERM)
    }

    @Test func sendsOutputToTheGivenDescriptorsWithTheGivenEnvironment() async throws {
        let stdout = Pipe(), stderr = Pipe()
        let process = try DisclaimedProcess.spawn(
            "/bin/sh", ["-c", #"printf '%s' "$GREETING"; printf oops >&2"#], environment: ["GREETING": "hi"],
            stdout: .fileDescriptor(stdout.fileHandleForWriting.fileDescriptor),
            stderr: .fileDescriptor(stderr.fileHandleForWriting.fileDescriptor)
        )
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        #expect(await process.waitForExit() == 0)
        #expect(String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "hi")
        #expect(String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "oops")
    }

    @Test func stdinIsEmptyByDefault() async throws {
        let process = try DisclaimedProcess.spawn("/bin/sh", ["-c", #"test -z "$(cat)""#])
        #expect(await process.waitForExit() == 0)
    }

    @Test func aMissingExecutableThrows() {
        #expect(throws: VMError.self) { try DisclaimedProcess.spawn("/nonexistent/hobo-test", []) }
    }
}
