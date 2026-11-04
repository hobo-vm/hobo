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

    /// An ephemeral VM's process deletes its bundle as it exits.
    @Test func stopReportsAnEphemeralVMsDeletion() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let bundle = store.bundle(for: "dev")
        let server = try ControlServer(path: store.job(for: "dev").socket) { [launchctl] _, _ in
            try? FileManager.default.removeItem(at: bundle)
            launchctl.pid.withLock { $0 = nil }
            return .accepted
        }
        defer { server.close() }
        #expect(try await lifecycle.stop("dev", force: false) == .deleted)
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

    /// Makes `dev` an ephemeral VM whose VM process has booted it.
    func makeEphemeralAndStarted() throws {
        let configFile = store.bundle(for: "dev").appending(path: VMStore.configFile)
        var config = try VMConfig.load(from: configFile)
        config.ephemeral = true
        try config.write(to: configFile)
        try Data().write(to: store.bundle(for: "dev").appending(path: VMStore.startedMarker))
    }

    /// A killed VM process can't delete its ephemeral VM as it exits; `stop` finding it again does.
    @Test func forceDeletesAKilledEphemeralVM() async throws {
        defer { cleanUp() }
        try makeEphemeralAndStarted()
        let log = store.job(for: "dev").log
        try Data("x".utf8).write(to: log)
        launchctl.pid.withLock { $0 = 4242 }
        #expect(try await lifecycle.stop("dev", force: true) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
        // As after any failed run, its log stays.
        #expect(FileManager.default.fileExists(atPath: log.path))
    }

    @Test func deleteRefusesARunningVMWithoutForce() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        await #expect(throws: VMStoreError.busy("dev", reason: "running (hobo stop dev)")) { try await lifecycle.delete("dev", force: false) }
        #expect(!launchctl.called("kill"))
        #expect(FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
    }

    @Test func forceDeleteStopsARunningVMAndDeletesIt() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        // Refuses a graceful stop: delete --force must not wait for the guest to shut down.
        let server = try ControlServer(path: store.job(for: "dev").socket) { [launchctl] request, _ in
            guard case .stop(force: true) = request else { return .error("expected a forced stop") }
            launchctl.pid.withLock { $0 = nil }
            return .accepted
        }
        defer { server.close() }
        try await lifecycle.delete("dev", force: true)
        #expect(!launchctl.called("kill"))
        #expect(!FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
    }

    @Test func forceDeleteKillsASilentProcess() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        try await lifecycle.delete("dev", force: true)
        #expect(launchctl.called("kill"))
        #expect(!FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
    }

    /// Stopping it deleted it, which mustn't then fail as "not found".
    @Test func forceDeleteOfAnEphemeralVM() async throws {
        defer { cleanUp() }
        try makeEphemeralAndStarted()
        launchctl.pid.withLock { $0 = 4242 }
        try await lifecycle.delete("dev", force: true)
        #expect(!FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
    }

    @Test func forceDeleteOfAStoppedVMStopsNothing() async throws {
        defer { cleanUp() }
        try await lifecycle.delete("dev", force: true)
        #expect(!launchctl.called("kill"))
        #expect(!FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
    }

    @Test func forceDeleteOfASuspendedVM() async throws {
        defer { cleanUp() }
        try suspend()
        try await lifecycle.delete("dev", force: true)
        #expect(!FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
    }

    @Test func forceDeleteRefusesAVMBeingBuilt() async throws {
        defer { cleanUp() }
        _ = try store.beginCreate("new")
        await #expect(throws: VMStoreError.busy("new", reason: "being built")) { try await lifecycle.delete("new", force: true) }
        #expect(FileManager.default.fileExists(atPath: store.bundle(for: "new").path))
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

    /// Gives `dev` saved state, as a suspend leaves it, recording `shares`; nil leaves out `run.json`.
    func suspend(shares: [VMShare]? = []) throws {
        let directory = SavedState.directory(in: store.bundle(for: "dev"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 4096).write(to: directory.appending(path: SavedState.stateFile))
        if let shares { try SuspendedRun(shares: shares, suspendedAt: .now).write(to: directory.appending(path: SavedState.runFile)) }
    }

    var isSuspended: Bool { SavedState.load(in: store.bundle(for: "dev")) != nil }

    @Test(arguments: [false, true])
    func stopRefusesASuspendedVM(force: Bool) async throws {
        defer { cleanUp() }
        try suspend()
        await #expect(throws: LifecycleError.suspended("dev")) { try await lifecycle.stop("dev", force: force) }
        #expect(isSuspended)
    }

    @Test func runSharesCantBeAddedToAResumingVM() async throws {
        defer { cleanUp() }
        try suspend()
        let share = VMShare(name: "tmp", path: "/tmp", readOnly: false)
        await #expect(throws: LifecycleError.sharesNeedCold("dev")) { try await lifecycle.start("dev", shares: [share]) }
        #expect(isSuspended)
    }

    @Test func resumeNeedsTheRecordedShareFolders() async throws {
        defer { cleanUp() }
        try suspend(shares: [VMShare(name: "gone", path: "/nonexistent-\(UUID().uuidString)", readOnly: false)])
        await #expect { try await lifecycle.start("dev") } throws: { error in
            guard case LifecycleError.cantResume("dev", let reason) = error else { return false }
            return reason.contains("nonexistent")
        }
        #expect(isSuspended)
    }

    @Test func resumeNeedsARunFile() async throws {
        defer { cleanUp() }
        try suspend(shares: nil)
        await #expect(throws: LifecycleError.cantResume("dev", "its run.json is unreadable")) { try await lifecycle.start("dev") }
    }

    /// The test binary lacks the virtualization entitlement, so this start fails, and must do so
    /// before it discards anything.
    @Test func coldStartKeepsTheStateIfItCantBoot() async throws {
        defer { cleanUp() }
        try suspend()
        await #expect(throws: LifecycleError.unsigned("/bin/hobo")) { try await lifecycle.start("dev", cold: true) }
        #expect(isSuspended)
    }

    @Test func suspendWaitsForTheSavedState() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let server = try ControlServer(path: store.job(for: "dev").socket) { [launchctl] request, _ in
            guard request == .suspend else { return .error("unexpected \(request)") }
            try? suspend()
            launchctl.pid.withLock { $0 = nil }
            return .accepted
        }
        defer { server.close() }
        guard case .suspended(let bytes) = try await lifecycle.suspend("dev") else { Issue.record("not suspended"); return }
        #expect(bytes >= 4096)
        #expect(launchctl.called("bootout"))
    }

    @Test func suspendReportsAFailedSave() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let server = try serve(.error("suspending dev failed: no space"))
        defer { server.close() }
        await #expect(throws: LifecycleError.refused("dev", "suspending dev failed: no space")) { try await lifecycle.suspend("dev") }
    }

    @Test func suspendReportsAProcessThatExitsWithoutState() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 4242 }
        let server = try ControlServer(path: store.job(for: "dev").socket) { [launchctl] _, _ in
            launchctl.pid.withLock { $0 = nil }
            return .accepted
        }
        defer { server.close() }
        await #expect { try await lifecycle.suspend("dev") } throws: { error in
            guard case LifecycleError.exited("dev", _, _) = error else { return false }
            return true
        }
    }

    @Test func suspendOfAStoppedOrSuspendedVMDoesNothing() async throws {
        defer { cleanUp() }
        #expect(try await lifecycle.suspend("dev") == .wasNotRunning)
        try suspend()
        guard case .alreadySuspended = try await lifecycle.suspend("dev") else { Issue.record("not already suspended"); return }
    }

    @Test func discardReportsWhetherThereWasState() throws {
        defer { cleanUp() }
        #expect(try lifecycle.discard("dev") == .notSuspended)
        try suspend()
        #expect(try lifecycle.discard("dev") == .discarded)
        #expect(!isSuspended)
        // Clears a failed resume's exit status, so the VM shows as stopped, not crashed.
        #expect(launchctl.called("bootout"))
    }

    /// With its saved state gone, a suspended ephemeral VM that had run has stopped, so it goes.
    @Test func discardDeletesAnEphemeralVM() throws {
        defer { cleanUp() }
        try makeEphemeralAndStarted()
        try suspend()
        #expect(try lifecycle.discard("dev") == .deleted)
        #expect(!FileManager.default.fileExists(atPath: store.bundle(for: "dev").path))
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
        #expect(try json(VMLifecycle.StartResult.resumed(status))
            == #"{"outcome":"resumed","status":{"ipAddress":"192.168.64.5","pid":42,"state":"running","windowShown":false}}"#)
        #expect(try json(VMLifecycle.StartResult.alreadyRunning(nil)) == #"{"outcome":"alreadyRunning"}"#)
        #expect(try json(NamedStartResult(name: "dev-3f9a", result: .started(status)))
            == #"{"name":"dev-3f9a","outcome":"started","status":{"ipAddress":"192.168.64.5","pid":42,"state":"running","windowShown":false}}"#)
    }

    @Test func stopResults() throws {
        #expect(try json(VMLifecycle.StopResult.stopped) == #"{"outcome":"stopped"}"#)
        #expect(try json(VMLifecycle.StopResult.deleted) == #"{"outcome":"deleted"}"#)
        #expect(try json(VMLifecycle.StopResult.wasNotRunning) == #"{"outcome":"wasNotRunning"}"#)
    }

    @Test func suspendResults() throws {
        #expect(try json(VMLifecycle.SuspendResult.suspended(savedStateBytes: 7)) == #"{"outcome":"suspended","savedStateBytes":7}"#)
        #expect(try json(VMLifecycle.SuspendResult.alreadySuspended(savedStateBytes: 7))
            == #"{"outcome":"alreadySuspended","savedStateBytes":7}"#)
        #expect(try json(VMLifecycle.SuspendResult.wasNotRunning) == #"{"outcome":"wasNotRunning"}"#)
    }

    @Test func discardResults() throws {
        #expect(try json(VMLifecycle.DiscardResult.discarded) == #"{"outcome":"discarded"}"#)
        #expect(try json(VMLifecycle.DiscardResult.deleted) == #"{"outcome":"deleted"}"#)
        #expect(try json(VMLifecycle.DiscardResult.notSuspended) == #"{"outcome":"notSuspended"}"#)
    }
}
