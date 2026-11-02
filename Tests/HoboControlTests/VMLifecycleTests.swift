import Foundation
import HoboCore
import Synchronization
import Testing
@testable import HoboControl

/// `stop` and `view` against a fake launchd and a real control socket: which path each takes
/// when the VM process answers, refuses, or is silent.
@Suite struct VMLifecycleTests {
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
        try ControlServer(path: store.job(for: "dev").socket) { [launchctl] request, _ in
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

    @Test func tailKeepsTheLastLines() throws {
        defer { cleanUp() }
        let log = store.directory.appending(path: "dev.log")
        try (1...30).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        #expect(VMLifecycle.tail(of: log, lines: 3) == "line 28\nline 29\nline 30")
        #expect(VMLifecycle.tail(of: log.appending(path: "missing")).isEmpty)
    }

    @Test func viewRefusesAStoppedVM() async throws {
        defer { cleanUp() }
        await #expect(throws: LifecycleError.notRunning("dev")) { try await lifecycle.view("dev") }
    }

    @Test func viewAsksTheVMProcessForTheWindow() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let requests: Mutex<[ControlRequest]> = Mutex([])
        let server = try ControlServer(path: store.job(for: "dev").socket) { request, _ in
            requests.withLock { $0.append(request) }
            return .accepted
        }
        defer { server.close() }
        try await lifecycle.view("dev")
        #expect(requests.withLock { $0 } == [.view])
    }

    @Test func viewReportsARefusal() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let server = try serve(.error("dev is shutting down"))
        defer { server.close() }
        await #expect(throws: LifecycleError.refused("dev", "dev is shutting down")) { try await lifecycle.view("dev") }
    }

    @Test func viewReportsASilentProcess() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        await #expect { try await lifecycle.view("dev") } throws: { error in
            guard case LifecycleError.unresponsive("dev", _) = error else { return false }
            return true
        }
    }

    @Test(arguments: [false, true])
    func startingARunningVMShowsItsWindowOnlyWithGUI(gui: Bool) async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let status = VMRunStatus(state: .running, pid: 4242)
        let requests: Mutex<[ControlRequest]> = Mutex([])
        let server = try ControlServer(path: store.job(for: "dev").socket) { request, _ in
            requests.withLock { $0.append(request) }
            return request == .status ? .status(status) : .accepted
        }
        defer { server.close() }
        #expect(try await lifecycle.start("dev", gui: gui) == .alreadyRunning(status))
        #expect(requests.withLock { $0 } == (gui ? [.view, .status] : [.status]))
    }

    @Test func sharesCantBeAddedToARunningVM() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let share = VMShare(name: "tmp", path: "/tmp", readOnly: false)
        await #expect(throws: LifecycleError.sharesNeedStop("dev")) { try await lifecycle.start("dev", shares: [share]) }
    }

    @Test func runSharesGoToTheVMProcess() {
        let shares = [VMShare(name: "a", path: "/x/a", readOnly: false), VMShare(name: "b", path: "/x/b", readOnly: true)]
        let arguments = VMLifecycle.runArguments(executable: URL(filePath: "/bin/hobo"), name: "dev", gui: false, shares: shares)
        #expect(arguments == ["/bin/hobo", "_vm-run", "dev", "--share", "/x/a", "--share", "/x/b:ro"])
    }

    @Test(arguments: [false, true])
    func onlyGUIStartsAskTheVMProcessForAWindow(gui: Bool) {
        let arguments = VMLifecycle.runArguments(executable: URL(filePath: "/bin/hobo"), name: "dev", gui: gui)
        #expect(arguments == ["/bin/hobo", "_vm-run", "dev"] + (gui ? ["--gui"] : []))
    }
}

@Suite struct LifecycleResultJSONTests {
    private func json(_ value: some Encodable) throws -> String { String(decoding: try HoboJSON.line(value), as: UTF8.self) }

    @Test func startResults() throws {
        let status = VMRunStatus(state: .running, pid: 42, ipAddress: "192.168.64.5")
        #expect(try json(VMLifecycle.StartResult.started(status))
            == #"{"outcome":"started","status":{"ipAddress":"192.168.64.5","pid":42,"state":"running","windowShown":false}}"#)
        #expect(try json(VMLifecycle.StartResult.alreadyRunning(nil)) == #"{"outcome":"alreadyRunning"}"#)
    }

    @Test func stopResults() throws {
        #expect(try json(VMLifecycle.StopResult.stopped) == #"{"outcome":"stopped"}"#)
        #expect(try json(VMLifecycle.StopResult.wasNotRunning) == #"{"outcome":"wasNotRunning"}"#)
    }
}
