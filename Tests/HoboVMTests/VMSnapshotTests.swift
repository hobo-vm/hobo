import Foundation
import HoboControl
import HoboCore
import Synchronization
import Testing
@testable import HoboVM

/// `hobo snapshot` against a store with a fake launchd and stand-in platform files. Needs no VM, so
/// it runs without HOBO_INTEGRATION; the integration tests cover a guest going through it.
@Suite struct VMSnapshotTests {
    /// Stands in for `launchctl`: `dev`'s job runs while `pid` is set, and `kill` ends it.
    final class FakeLaunchctl: Sendable {
        let label: Mutex<String> = Mutex("")
        let pid: Mutex<Int32?> = Mutex(nil)

        var launchd: Launchd {
            Launchd { arguments in
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
    }

    let launchctl = FakeLaunchctl()
    let store: VMStore
    let lifecycle: VMLifecycle
    let bundle: URL
    let config = VMConfig(
        engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
        guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 1_800_000_000),
        recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
    )

    init() throws {
        // Short, since the socket lives in the home and socket paths are capped at 103 bytes.
        let home = HoboHome(root: URL(filePath: "/tmp/hobo-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        store = VMStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "hobo-vms-\(UUID().uuidString)"),
            home: home, launchd: launchctl.launchd
        )
        lifecycle = VMLifecycle(store: store, executable: URL(filePath: "/bin/hobo")) { _ in }
        bundle = store.bundle(for: "dev")
        _ = try store.beginCreate("dev")
        try writeDisk("then")
        try store.finishCreate("dev", config: config, recipe: Data())
        let label = store.job(for: "dev").label
        launchctl.label.withLock { $0 = label }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: store.directory)
        try? FileManager.default.removeItem(at: store.home.root)
    }

    /// Every platform file gets `text`, as a guest moving on would change them.
    func writeDisk(_ text: String) throws {
        for name in MacVMBundle.platformFiles { try Data(text.utf8).write(to: bundle.appending(path: name)) }
    }

    /// Makes the VM suspended, as `hobo suspend` leaves one.
    func suspend(state: String = "memory") throws {
        let directory = SavedState.directory(in: bundle)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(state.utf8).write(to: directory.appending(path: SavedState.stateFile))
        try SuspendedRun(shares: [], suspendedAt: .now).write(to: directory.appending(path: SavedState.runFile))
    }

    func platformFilesAll(say text: String, in directory: URL) throws -> Bool {
        try MacVMBundle.platformFiles.allSatisfy { try Data(contentsOf: directory.appending(path: $0)) == Data(text.utf8) }
    }

    func savedState(in directory: URL) throws -> String {
        try String(contentsOf: SavedState.directory(in: directory).appending(path: SavedState.stateFile), encoding: .utf8)
    }

    func writeConfig(_ change: (inout VMConfig) -> Void) throws {
        let file = bundle.appending(path: VMStore.configFile)
        var config = try VMConfig.load(from: file)
        change(&config)
        try config.write(to: file)
    }

    var storedConfig: VMConfig { get throws { try VMConfig.load(from: bundle.appending(path: VMStore.configFile)) } }

    @Test func aStoppedVMsSnapshotIsDiskOnlyAndLeavesItStopped() async throws {
        defer { cleanUp() }
        let snapshot = try await lifecycle.saveSnapshot("dev", tag: "clean")
        #expect(!snapshot.isLive)
        #expect(snapshot.record.disk == config.disk)
        #expect(try platformFilesAll(say: "then", in: Snapshot.directory("clean", in: bundle)))
        guard case .stopped = try store.find("dev").status else { Issue.record("not stopped"); return }
    }

    @Test func aSuspendedVMsSnapshotIsLiveAndLeavesItSuspended() async throws {
        defer { cleanUp() }
        try suspend()
        let snapshot = try await lifecycle.saveSnapshot("dev", tag: "clean")
        #expect(snapshot.isLive)
        #expect(try savedState(in: Snapshot.directory("clean", in: bundle)) == "memory")
        guard case .suspended = try store.find("dev").status else { Issue.record("not suspended"); return }
    }

    /// A running VM's process does the saving; the client only asks and reports.
    @Test func aRunningVMsProcessSavesTheSnapshot() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 123 }
        let asked = Mutex<ControlRequest?>(nil)
        let (bundle, config) = (bundle, config)
        let server = try ControlServer(path: store.job(for: "dev").socket) { request, _ in
            asked.withLock { $0 = request }
            let partial = try! Snapshot.begin("clean", in: bundle)
            try! Snapshot.finish("clean", partial: partial, in: bundle, config: config)
            return .accepted
        }
        defer { server.close() }
        #expect(try await lifecycle.saveSnapshot("dev", tag: "clean").tag == "clean")
        #expect(asked.withLock { $0 } == .snapshot(tag: "clean"))
    }

    @Test func aFailedSaveByTheVMProcessIsReported() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 123 }
        let server = try ControlServer(path: store.job(for: "dev").socket) { _, _ in .error("no space") }
        defer { server.close() }
        await #expect(throws: LifecycleError.refused("dev", "no space")) {
            _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        }
    }

    /// Stopping would delete it and its snapshots, so restoring could never work.
    @Test func anEphemeralVMCantBeSnapshotted() async throws {
        defer { cleanUp() }
        try writeConfig { $0.ephemeral = true }
        await #expect(throws: SnapshotError.ephemeral("dev")) { _ = try await lifecycle.saveSnapshot("dev", tag: "clean") }
    }

    @Test func aTagIsNeitherReusedNorInvalid() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        try writeDisk("now")
        await #expect(throws: SnapshotError.exists("dev", "clean")) { _ = try await lifecycle.saveSnapshot("dev", tag: "CLEAN") }
        #expect(try platformFilesAll(say: "then", in: Snapshot.directory("clean", in: bundle)))
        for tag in ["../up", ".hidden", "a/b", ""] {
            await #expect(throws: SnapshotError.invalidTag(tag)) { _ = try await lifecycle.saveSnapshot("dev", tag: tag) }
        }
    }

    /// A save that failed leaves nothing listed and doesn't take the tag.
    @Test func aFailedSaveLeavesNoSnapshot() async throws {
        defer { cleanUp() }
        try FileManager.default.removeItem(at: bundle.appending(path: "aux.img"))
        await #expect(throws: (any Error).self) { _ = try await lifecycle.saveSnapshot("dev", tag: "clean") }
        #expect(Snapshot.list(in: bundle).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Snapshot.root(in: bundle).path).isEmpty)
    }

    /// What a crash left isn't listed, and the next save clears it.
    @Test func aCrashedSaveIsIgnoredThenCleared() async throws {
        defer { cleanUp() }
        let partial = try Snapshot.begin("crashed", in: bundle)
        #expect(Snapshot.list(in: bundle).isEmpty)
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(Snapshot.list(in: bundle).map(\.tag) == ["clean"])
    }

    /// Restoring clones from the snapshot, so a second restore finds it as it was.
    @Test func aDiskOnlyRestoreLeavesItStoppedAndTheSnapshotIntact() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        for _ in 0..<2 {
            try writeDisk("now")
            #expect(try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false) == .stopped)
            #expect(try platformFilesAll(say: "then", in: bundle))
        }
        #expect(!FileManager.default.fileExists(atPath: bundle.appending(path: VMStore.restoringDirectory).path))
        guard case .stopped = try store.find("dev").status else { Issue.record("not stopped"); return }
    }

    @Test func aMissingTagFailsBeforeTouchingTheVM() async throws {
        defer { cleanUp() }
        try suspend()
        await #expect(throws: SnapshotError.notFound("dev", "nope")) {
            _ = try await lifecycle.restoreSnapshot("dev", tag: "nope", force: true)
        }
        #expect(try savedState(in: bundle) == "memory")
    }

    /// A live snapshot lays its state down as the VM's, leaving it suspended for the ordinary resume.
    /// This stops short of that start, which needs the entitlement the test binary lacks.
    @Test func aLiveRestoreLeavesSavedStateForTheResume() throws {
        defer { cleanUp() }
        try suspend()
        try store.snapshotAtRest(bundle, tag: "clean", config: config)
        try FileManager.default.removeItem(at: SavedState.directory(in: bundle))
        try writeDisk("now")
        try store.restoreFiles(of: Snapshot.find("clean", in: bundle), into: bundle) { _ in }
        #expect(try platformFilesAll(say: "then", in: bundle))
        #expect(try savedState(in: bundle) == "memory")
        guard case .suspended = try store.find("dev").status else { Issue.record("not suspended"); return }
        #expect(try savedState(in: Snapshot.directory("clean", in: bundle)) == "memory", "the snapshot keeps its own")
    }

    @Test func restoringOverASuspendedVMNeedsForce() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        try suspend(state: "later")
        await #expect(throws: SnapshotError.needsForce("dev", tag: "clean", state: "suspended")) {
            _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false)
        }
        #expect(try savedState(in: bundle) == "later")
        #expect(try await lifecycle.restoreSnapshot("dev", tag: "clean", force: true) == .stopped)
        #expect(SavedState.load(in: bundle) == nil, "a disk-only snapshot has no memory to go with its disk")
    }

    @Test func restoringOverARunningVMNeedsForceWhichPowersItOff() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        launchctl.pid.withLock { $0 = 123 }
        await #expect(throws: SnapshotError.needsForce("dev", tag: "clean", state: "running")) {
            _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false)
        }
        #expect(launchctl.pid.withLock { $0 } == 123)
        // No VM process is answering, so the forced stop kills the job.
        try writeDisk("now")
        #expect(try await lifecycle.restoreSnapshot("dev", tag: "clean", force: true) == .stopped)
        #expect(launchctl.pid.withLock { $0 } == nil)
        #expect(try platformFilesAll(say: "then", in: bundle))
    }

    /// Decision 13: VZ refuses state saved with another CPU or memory configuration, so only the
    /// disk comes back, the current configuration stays, and it says so.
    @Test(arguments: [false, true])
    func stateThatNoLongerFitsIsLeftBehindWithAWarning(changeCPUs: Bool) throws {
        defer { cleanUp() }
        try suspend()
        try store.snapshotAtRest(bundle, tag: "clean", config: config)
        try FileManager.default.removeItem(at: SavedState.directory(in: bundle))
        try writeConfig { if changeCPUs { $0.cpus = 2 } else { $0.memory = 4 << 30 } }
        let expected = try storedConfig
        try writeDisk("now")
        let logged = Mutex<[String]>([])
        try store.restoreFiles(of: Snapshot.find("clean", in: bundle), into: bundle) { message in logged.withLock { $0.append(message) } }
        #expect(try platformFilesAll(say: "then", in: bundle))
        #expect(SavedState.load(in: bundle) == nil)
        #expect(try storedConfig == expected)
        #expect(logged.withLock { $0.contains { $0.hasPrefix("warning:") } })
    }

    /// The image is the size it was then, so the config must say so. That doesn't touch the state.
    @Test func theDiskGoesBackToItsSizeThenKeepingTheState() throws {
        defer { cleanUp() }
        try suspend()
        try store.snapshotAtRest(bundle, tag: "clean", config: config)
        try FileManager.default.removeItem(at: SavedState.directory(in: bundle))
        try writeConfig {
            $0.disk = 100 << 30
            $0.diskGrowPending = true
        }
        let logged = Mutex<[String]>([])
        try store.restoreFiles(of: Snapshot.find("clean", in: bundle), into: bundle) { message in logged.withLock { $0.append(message) } }
        #expect(try storedConfig.disk == config.disk)
        #expect(try storedConfig.diskGrowPending == false)
        #expect(SavedState.load(in: bundle) != nil)
        #expect(logged.withLock { $0.contains { $0.contains("hobo set --disk") } })
    }

    /// Other settings changed since (shares, `--keep`) aren't part of what a snapshot records.
    @Test func restoringKeepsOtherSettings() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        let share = VMShare(name: "code", path: "/tmp", readOnly: false)
        try writeConfig { $0.shares = [share] }
        _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false)
        #expect(try storedConfig.shares == [share])
    }

    @Test func listIsOldestFirstAndDeleteTakesOne() throws {
        defer { cleanUp() }
        for (tag, seconds) in [("b", 200.0), ("a", 300.0), ("c", 100.0)] {
            let partial = try Snapshot.begin(tag, in: bundle)
            try Snapshot.finish(tag, partial: partial, in: bundle, config: config, createdAt: Date(timeIntervalSince1970: seconds))
        }
        #expect(Snapshot.list(in: bundle).map(\.tag) == ["c", "b", "a"])
        try Snapshot.delete("B", in: bundle)
        #expect(Snapshot.list(in: bundle).map(\.tag) == ["c", "a"])
        #expect(throws: SnapshotError.notFound("dev", "b")) { try Snapshot.delete("b", in: bundle) }
    }

    /// A snapshot's disk is a clone, sharing the VM's blocks: only its saved state adds to the VM's size.
    @Test func theVMsSizeCountsOnlyASnapshotsSavedState() throws {
        defer { cleanUp() }
        let before = try store.find("dev").allocatedBytes
        try store.snapshotAtRest(bundle, tag: "disk-only", config: config)
        #expect(try store.find("dev").allocatedBytes == before)
        try suspend(state: String(repeating: "m", count: 1 << 20))
        try store.snapshotAtRest(bundle, tag: "live", config: config)
        let state = try #require(Snapshot.find("live", in: bundle).savedStateBytes)
        try FileManager.default.removeItem(at: SavedState.directory(in: bundle))
        #expect(try store.find("dev").allocatedBytes == before + state)
    }

    @Test func cloneLeavesSnapshotsAndRenameCarriesThem() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        let clone = try store.cloneVM("dev", to: "exp") { _ in }
        #expect(Snapshot.list(in: clone.bundle).isEmpty)
        try store.rename("dev", to: "renamed")
        #expect(Snapshot.list(in: store.bundle(for: "renamed")).map(\.tag) == ["clean"])
    }

    @Test func snapshotsEncodeTheirKind() throws {
        defer { cleanUp() }
        let record = SnapshotRecord(config: config, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let encoded = { (snapshot: Snapshot) throws -> String in
            String(decoding: try HoboJSON.line(snapshot), as: UTF8.self)
        }
        let disk = try encoded(Snapshot(tag: "a", record: record, savedStateBytes: nil))
        #expect(disk.contains(#""kind":"disk""#) && !disk.contains("savedStateBytes"))
        let live = try encoded(Snapshot(tag: "a", record: record, savedStateBytes: 5))
        #expect(live.contains(#""kind":"live""#) && live.contains(#""savedStateBytes":5"#))
    }

    /// Run by the local shell, standing in for a guest's: it must pass only near the given time.
    @Test(arguments: [(0.0, true), (2.0, true), (-2.0, true), (10.0, false), (-10.0, false)])
    func clockAgreement(offset: Double, agrees: Bool) throws {
        defer { cleanUp() }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        // A second may pass between building this and running it, so the edge cases keep inside it.
        let margin = offset > 0 ? -1.0 : offset < 0 ? 1.0 : 0
        shell.arguments = ["-c", clockAgreesCommand(Date.now.addingTimeInterval(offset + (abs(offset) == 2 ? margin : 0)))]
        try shell.run()
        shell.waitUntilExit()
        #expect((shell.terminationStatus == 0) == agrees)
    }

    @Test func restoreResults() throws {
        defer { cleanUp() }
        #expect(String(decoding: try HoboJSON.line(VMLifecycle.RestoreResult.stopped), as: UTF8.self).contains(#""outcome":"stopped""#))
        let status = VMRunStatus(state: .running, pid: 1)
        let resumed = String(decoding: try HoboJSON.line(VMLifecycle.RestoreResult.started(.resumed(status))), as: UTF8.self)
        #expect(resumed.contains(#""outcome":"resumed""#) && resumed.contains(#""status""#))
    }
}
