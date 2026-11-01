import Foundation
import HoboCore
import Synchronization
import Testing
@testable import HoboControl

/// `stop` against a fake launchd and a real control socket: which path it takes when the VM
/// process answers, refuses, or is silent.
@Suite struct VMLifecycleStopTests {
    /// Stands in for `launchctl`: one job, `dev`'s, whose process runs while `pid` is set.
    /// `kill` ends the process, and every call is recorded.
    final class FakeLaunchctl: Sendable {
        let label: Mutex<String> = Mutex("")
        let pid: Mutex<Int32?> = Mutex(nil)
        let calls: Mutex<[[String]]> = Mutex([])

        var launchd: Launchd {
            Launchd { arguments in
                self.calls.withLock { $0.append(arguments) }
                switch arguments.first {
                case "list":
                    let pid = self.pid.withLock { $0 }.map(String.init) ?? "-"
                    return (0, "PID\tStatus\tLabel\n\(pid)\t0\t\(self.label.withLock { $0 })\n")
                case "kill":
                    self.pid.withLock { $0 = nil }
                    return (0, "")
                default:
                    return (0, "")
                }
            }
        }

        func called(_ verb: String) -> Bool { calls.withLock { $0.contains { $0.first == verb } } }
    }

    let launchctl = FakeLaunchctl()
    let store: VMStore
    let lifecycle: VMLifecycle

    init() throws {
        // Short, since the socket lives in the home and socket paths are capped at 103 bytes.
        let home = HoboHome(root: URL(filePath: "/tmp/hobo-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        store = VMStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "hobo-vms-\(UUID().uuidString)"),
            home: home, launchd: launchctl.launchd
        )
        _ = try store.beginCreate("dev")
        try store.finishCreate("dev", config: VMConfig(
            engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
            guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 1_800_000_000),
            recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
        ), recipe: Data("cpus = 4\n".utf8))
        lifecycle = VMLifecycle(store: store, executable: URL(filePath: "/bin/hobo")) { _ in }
        let label = store.job(for: "dev").label
        launchctl.label.withLock { $0 = label }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: store.directory)
        try? FileManager.default.removeItem(at: store.home.root)
    }

    /// A VM process that answers `stop` with `response`, exiting if it is `.accepted`.
    func serve(_ response: ControlResponse) throws -> ControlServer {
        try ControlServer(path: store.job(for: "dev").socket) { [launchctl] request in
            if case .stop = request, response == .accepted { launchctl.pid.withLock { $0 = nil } }
            return response
        }
    }

    @Test func notRunningClearsTheJob() async throws {
        defer { cleanUp() }
        #expect(try await lifecycle.stop("dev", force: false) == .wasNotRunning)
        #expect(launchctl.called("bootout"))
    }

    @Test(arguments: [false, true])
    func acceptedStopWaitsForTheProcessToExit(force: Bool) async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let server = try serve(.accepted)
        defer { server.close() }
        #expect(try await lifecycle.stop("dev", force: force) == .stopped)
        #expect(!launchctl.called("kill"))
        #expect(launchctl.called("bootout"))
    }

    @Test func silentProcessIsReportedWithoutForce() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        await #expect {
            try await lifecycle.stop("dev", force: false)
        } throws: { error in
            guard case LifecycleError.unresponsive("dev", _) = error else { return false }
            return true
        }
        #expect(!launchctl.called("kill"))
    }

    @Test func refusalIsReportedWithoutForce() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let server = try serve(.error("nope"))
        defer { server.close() }
        await #expect(throws: LifecycleError.refused("dev", "nope")) { try await lifecycle.stop("dev", force: false) }
        #expect(!launchctl.called("kill"))
    }

    @Test func forceKillsASilentProcess() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        #expect(try await lifecycle.stop("dev", force: true) == .stopped)
        #expect(launchctl.calls.withLock { $0 }.contains(["kill", "SIGKILL", "gui/\(getuid())/\(store.job(for: "dev").label)"]))
    }

    @Test func forceKillsARefusingProcess() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let server = try serve(.error("speaks protocol 2"))
        defer { server.close() }
        #expect(try await lifecycle.stop("dev", force: true) == .stopped)
        #expect(launchctl.called("kill"))
    }
}

@Suite struct LifecycleResultJSONTests {
    private func json(_ value: some Encodable) throws -> String { String(decoding: try HoboJSON.line(value), as: UTF8.self) }

    @Test func startResults() throws {
        let status = VMRunStatus(state: .running, pid: 42, ipAddress: "192.168.64.5")
        #expect(try json(VMLifecycle.StartResult.started(status))
            == #"{"outcome":"started","status":{"ipAddress":"192.168.64.5","pid":42,"state":"running"}}"#)
        #expect(try json(VMLifecycle.StartResult.alreadyRunning(nil)) == #"{"outcome":"alreadyRunning"}"#)
    }

    @Test func stopResults() throws {
        #expect(try json(VMLifecycle.StopResult.stopped) == #"{"outcome":"stopped"}"#)
        #expect(try json(VMLifecycle.StopResult.wasNotRunning) == #"{"outcome":"wasNotRunning"}"#)
    }
}
