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
        let lastExitStatus: Mutex<Int32> = Mutex(0)

        var launchd: Launchd {
            Launchd { arguments in
                switch arguments.first {
                case "list":
                    let pid = self.pid.withLock { $0 }.map(String.init) ?? "-"
                    return (0, "PID\tStatus\tLabel\n\(pid)\t\(self.lastExitStatus.withLock { $0 })\t\(self.label.withLock { $0 })\n")
                case "kill":
                    self.pid.withLock { $0 = nil }
                    return (0, "")
                case "bootout":
                    self.pid.withLock { $0 = nil }
                    self.lastExitStatus.withLock { $0 = 0 }
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
        os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
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

    /// Makes the VM running, with a process that exits a moment after the client's request has failed,
    /// as launchd only says so a moment after the connection closes. `lastAct` is its last work.
    func processExitsShortly(after lastAct: @escaping @Sendable () throws -> Void = {}) -> Task<Void, any Error> {
        launchctl.pid.withLock { $0 = 123 }
        let launchctl = launchctl
        return Task {
            try await Task.sleep(for: .milliseconds(300))
            try lastAct()
            launchctl.pid.withLock { $0 = nil }
        }
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

    @Test func aVMProcessThatDoesntAnswerIsReportedUnresponsive() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 123 }
        let error = await #expect(throws: LifecycleError.self) { _ = try await lifecycle.saveSnapshot("dev", tag: "clean") }
        guard case .unresponsive("dev", _) = error else { Issue.record("got \(String(describing: error))"); return }
    }

    /// The connection closes as the process exits, and launchd only says so a moment later.
    @Test func aVMThatStopsDuringTheSaveIsReportedAsStopped() async throws {
        defer { cleanUp() }
        let exit = processExitsShortly()
        defer { exit.cancel() }
        await #expect(throws: SnapshotError.stoppedWhileSaving("dev", tag: "clean")) {
            _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        }
    }

    /// The snapshot is in place before the process resumes the guest, so it can die with the save done.
    @Test func aVMThatStopsAfterTheSaveFinishedStillReportsTheSnapshot() async throws {
        defer { cleanUp() }
        let (bundle, config) = (bundle, config)
        let exit = processExitsShortly {
            let partial = try Snapshot.begin("clean", in: bundle)
            try Snapshot.finish("clean", partial: partial, in: bundle, config: config)
        }
        defer { exit.cancel() }
        #expect(try await lifecycle.saveSnapshot("dev", tag: "clean").tag == "clean")
    }

    /// The tag found afterwards is the earlier snapshot, not this save.
    @Test func aVMThatStopsDuringASaveToATakenTagIsReportedAsStopped() async throws {
        defer { cleanUp() }
        let partial = try Snapshot.begin("clean", in: bundle)
        try Snapshot.finish("clean", partial: partial, in: bundle, config: config)
        let exit = processExitsShortly()
        defer { exit.cancel() }
        await #expect(throws: SnapshotError.stoppedWhileSaving("dev", tag: "clean")) {
            _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        }
    }

    /// What a VM process from before snapshots answers, unable to decode the request.
    @Test func aVMProcessFromAnOlderHoboIsToldApart() async throws {
        defer { cleanUp() }
        launchctl.pid.withLock { $0 = 123 }
        let undecodable = String(describing: ControlError.badMessage("DecodingError.typeMismatch"))
        let server = try ControlServer(path: store.job(for: "dev").socket) { _, _ in .error(undecodable) }
        defer { server.close() }
        await #expect(throws: SnapshotError.startedByOlderHobo("dev")) {
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

    /// A crash leaves nothing to lose, so no force; and the restored VM must not still show the crash.
    @Test func aCrashedVMCanBeSnapshottedAndRestoredAndThenShowsStopped() async throws {
        defer { cleanUp() }
        launchctl.lastExitStatus.withLock { $0 = 1 }
        guard case .crashed = try store.find("dev").status else { Issue.record("not crashed"); return }
        #expect(try await !lifecycle.saveSnapshot("dev", tag: "clean").isLive)
        try writeDisk("now")
        #expect(try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false) == .stopped)
        #expect(try platformFilesAll(say: "then", in: bundle))
        guard case .stopped = try store.find("dev").status else { Issue.record("not stopped"); return }
    }

    private func expectSaveAndRestoreRefused(
        with error: some Error & Equatable, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await #expect(throws: error, sourceLocation: sourceLocation) { _ = try await lifecycle.saveSnapshot("dev", tag: "other") }
        await #expect(throws: error, sourceLocation: sourceLocation) { _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: true) }
    }

    @Test func aVMWithoutAUsableBundleRefusesSnapshots() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        let marker = bundle.appending(path: VMStore.buildingMarker)

        try String(getpid()).write(to: marker, atomically: true, encoding: .utf8)
        await expectSaveAndRestoreRefused(with: VMStoreError.busy("dev", reason: "being built"))

        try Data("no pid".utf8).write(to: marker)
        await expectSaveAndRestoreRefused(with: SnapshotError.notSnapshottable("dev", "its build failed (hobo delete dev)"))

        try FileManager.default.removeItem(at: marker)
        try Data("not json".utf8).write(to: bundle.appending(path: VMStore.configFile))
        await expectSaveAndRestoreRefused(with: SnapshotError.notSnapshottable("dev", "its bundle has no valid config.json"))
    }

    /// Everything is gathered before anything is replaced, so the VM keeps its disk and saved state.
    @Test func aRestoreThatCantGatherItsFilesLeavesTheVMAsItWas() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        try writeDisk("now")
        try suspend(state: "later")
        try FileManager.default.removeItem(at: Snapshot.directory("clean", in: bundle).appending(path: "aux.img"))
        await #expect(throws: (any Error).self) { _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: true) }
        #expect(try platformFilesAll(say: "now", in: bundle))
        #expect(try savedState(in: bundle) == "later")
        #expect(!FileManager.default.fileExists(atPath: bundle.appending(path: VMStore.restoringDirectory).path))
    }

    /// What a restore or suspend that died partway left doesn't stop the next restore, which clears it.
    @Test func aRestoreClearsWhatADeadRestoreOrSuspendLeft() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        let leftovers = [bundle.appending(path: VMStore.restoringDirectory), SavedState.partialDirectory(in: bundle)]
        for leftover in leftovers {
            try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: false)
            try Data("stale".utf8).write(to: leftover.appending(path: "aux.img"))
        }
        try writeDisk("now")
        #expect(try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false) == .stopped)
        #expect(try platformFilesAll(say: "then", in: bundle))
        for leftover in leftovers { #expect(!FileManager.default.fileExists(atPath: leftover.path)) }
    }

    /// A saved state left in place would resume onto the restored disk, which it doesn't match.
    @Test func aSavedStateThatCantBeRemovedStopsTheRestoreBeforeTheDiskChanges() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        try writeDisk("now")
        try suspend(state: "later")
        let state = SavedState.directory(in: bundle).path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: state)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: state) }
        await #expect(throws: (any Error).self) { _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: true) }
        #expect(try platformFilesAll(say: "now", in: bundle))
        #expect(try savedState(in: bundle) == "later")
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

    /// A grow that hadn't reached the guest when the snapshot was taken is still owed to its disk.
    @Test func aDiskGrowPendingThenIsPendingAgain() async throws {
        defer { cleanUp() }
        try writeConfig { $0.diskGrowPending = true }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        try writeConfig { $0.diskGrowPending = false }
        _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false)
        #expect(try storedConfig.diskGrowPending)
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
        #expect(try Snapshot.find("C", in: bundle).tag == "c")
    }

    /// It can't be listed or restored, but its tag stays taken until `delete`, which still reaches it.
    @Test func aSnapshotWhoseRecordWontDecodeIsHiddenUntilDeleted() async throws {
        defer { cleanUp() }
        _ = try await lifecycle.saveSnapshot("dev", tag: "clean")
        try Data("not json".utf8).write(to: Snapshot.directory("clean", in: bundle).appending(path: Snapshot.recordFile))
        #expect(Snapshot.list(in: bundle).isEmpty)
        await #expect(throws: SnapshotError.notFound("dev", "clean")) {
            _ = try await lifecycle.restoreSnapshot("dev", tag: "clean", force: false)
        }
        await #expect(throws: SnapshotError.exists("dev", "clean")) { _ = try await lifecycle.saveSnapshot("dev", tag: "clean") }
        try Snapshot.delete("clean", in: bundle)
        #expect(try await lifecycle.saveSnapshot("dev", tag: "clean").tag == "clean")
    }

    /// Snapshots are measured apart from the VM, whose own size they leave alone.
    @Test func theVMsSizeLeavesOutItsSnapshots() throws {
        defer { cleanUp() }
        let before = try store.find("dev").allocatedBytes
        try store.snapshotAtRest(bundle, tag: "disk-only", config: config)
        #expect(try store.find("dev").allocatedBytes == before)
        try suspend(state: String(repeating: "m", count: 1 << 20))
        try store.snapshotAtRest(bundle, tag: "live", config: config)
        try FileManager.default.removeItem(at: SavedState.directory(in: bundle))
        #expect(try store.find("dev").allocatedBytes == before)
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
        #expect(!live.contains("uniqueBytes")) // As from `snapshot save`, which doesn't measure it.
        #expect(try encoded(Snapshot(tag: "a", record: record, savedStateBytes: nil, uniqueBytes: 0)).contains(#""uniqueBytes":0"#))
    }

    /// Run by the local shell, standing in for a guest's: it must pass only near the given time.
    /// The agreeing offsets stop a second short of the 2 s limit, as a second may pass before it runs.
    @Test(arguments: [(0.0, true), (1.0, true), (-1.0, true), (10.0, false), (-10.0, false)])
    func clockAgreement(offset: Double, agrees: Bool) throws {
        defer { cleanUp() }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", clockAgreesCommand(Date.now.addingTimeInterval(offset))]
        try shell.run()
        shell.waitUntilExit()
        #expect((shell.terminationStatus == 0) == agrees)
    }

    @Test func restoreResultsEncodeTheirOutcome() throws {
        defer { cleanUp() }
        #expect(String(decoding: try HoboJSON.line(VMLifecycle.RestoreResult.stopped), as: UTF8.self).contains(#""outcome":"stopped""#))
        let status = VMRunStatus(state: .running, pid: 1)
        let resumed = String(decoding: try HoboJSON.line(VMLifecycle.RestoreResult.started(.resumed(status))), as: UTF8.self)
        #expect(resumed.contains(#""outcome":"resumed""#) && resumed.contains(#""status""#))
    }
}
