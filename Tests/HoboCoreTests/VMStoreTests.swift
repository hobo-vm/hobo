import Foundation
import Synchronization
import Testing
@testable import HoboCore

@Suite struct VMStoreTests {
    let launchctl = FakeLaunchctl()
    let store: VMStore

    init() {
        let temp = FileManager.default.temporaryDirectory
        store = VMStore(
            directory: temp.appending(path: "hobo-vms-\(UUID().uuidString)"),
            home: HoboHome(root: temp.appending(path: "hobo-home-\(UUID().uuidString)")),
            launchd: launchctl.launchd
        )
    }
    let config = VMConfig(
        engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
        guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 1_800_000_000),
        recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
    )

    /// A finished VM called `name`.
    private func made(_ name: String) throws {
        _ = try store.beginCreate(name)
        try store.finishCreate(name, config: config, recipe: Data("cpus = 4\n".utf8))
    }

    /// A bundle whose build process has exited.
    private func orphaned(_ name: String) throws {
        let bundle = try store.beginCreate(name)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        try String(process.processIdentifier).write(to: bundle.appending(path: VMStore.buildingMarker), atomically: true, encoding: .utf8)
    }

    @Test(arguments: ["dev", "Dev-2", "a", "x.y_z", String(repeating: "a", count: 63)])
    func validNames(name: String) throws {
        try VMStore.validate(name)
    }

    @Test(arguments: ["", "-dev", ".dev", "my vm", "a/b", "dev!", "é", String(repeating: "a", count: 64)])
    func invalidNames(name: String) {
        #expect(throws: VMStoreError.invalidName(name)) { try VMStore.validate(name) }
    }

    @Test func emptyOrMissingDirectoryListsNothing() {
        #expect(store.list().isEmpty)
    }

    @Test func buildingThenFinished() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try store.beginCreate("dev")
        #expect(bundle.path == store.directory.appending(path: "dev.hobovm").path)
        #expect(try store.find("dev").status == .building(pid: getpid()))

        try store.finishCreate("dev", config: config, recipe: Data("cpus = 4\n".utf8))
        #expect(try store.find("dev").status == .stopped(config))
        #expect(try String(contentsOf: bundle.appending(path: VMStore.recipeFile), encoding: .utf8) == "cpus = 4\n")
        #expect(!FileManager.default.fileExists(atPath: bundle.appending(path: VMStore.buildingMarker).path))
    }

    @Test func configRoundTripsThroughJSON() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        let json = try String(contentsOf: store.bundle(for: "dev").appending(path: VMStore.configFile), encoding: .utf8)
        #expect(json.contains("\"created\" : \"2027-01-15T08:00:00Z\""))
        #expect(json.contains("\"engine\" : \"vz\""))
        #expect(json.contains("\"memory\" : 8589934592"))
    }

    @Test func deadBuildIsFailedAndDeletable() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try orphaned("dev")
        #expect(try store.find("dev").status == .failed)
        try store.delete("dev")
        #expect(store.list().isEmpty)
    }

    @Test func reusedPIDIsNotABuild() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try store.beginCreate("dev")
        // A marker written before this (live) process started names a builder that has since died.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: bundle.appending(path: VMStore.buildingMarker).path
        )
        #expect(try store.find("dev").status == .failed)
        try store.delete("dev")
    }

    @Test func liveBuildCannotBeDeletedOrRenamed() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        _ = try store.beginCreate("dev")
        #expect(throws: VMStoreError.busy("dev", reason: "being built")) { try store.delete("dev") }
        #expect(throws: VMStoreError.busy("dev", reason: "being built")) { try store.rename("dev", to: "other") }
    }

    @Test func abandonedCreateLeavesNothing() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try store.beginCreate("dev")
        try Data(count: 1024).write(to: bundle.appending(path: "disk.asif"))
        #expect(try store.find("dev").allocatedBytes >= 1024)
        try store.abandonCreate("dev")
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test func bundleWithoutConfigOrMarkerIsBroken() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.bundle(for: "dev"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.directory.appending(path: "notes"), withIntermediateDirectories: true)
        try Data().write(to: store.directory.appending(path: ".hobovm"))
        #expect(store.list().map(\.name) == ["dev"])
        #expect(try store.find("dev").status == .broken)
        try store.delete("dev")
    }

    @Test func namesCollideCaseInsensitively() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        try orphaned("failed")
        #expect(throws: VMStoreError.exists("dev")) { try store.beginCreate("DEV") }
        #expect(throws: VMStoreError.exists("failed")) { try store.beginCreate("failed") }
        #expect(throws: VMStoreError.exists("failed")) { try store.rename("dev", to: "Failed") }
        #expect(try store.find("DEV").name == "dev")
    }

    @Test func renameMovesTheBundle() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        try store.rename("dev", to: "exp")
        #expect(store.list().map(\.name) == ["exp"])
        #expect(try store.find("exp").status == .stopped(config))
        try store.rename("exp", to: "Exp")
        #expect(store.list().map(\.name) == ["Exp"])
        #expect(throws: VMStoreError.notFound("dev")) { try store.rename("dev", to: "x") }
        #expect(throws: VMStoreError.invalidName("a b")) { try store.rename("Exp", to: "a b") }
    }

    @Test func listIsSortedByName() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for name in ["b", "a10", "a2"] { try made(name) }
        #expect(store.list().map(\.name) == ["a2", "a10", "b"])
    }

    @Test func jobIsKeyedByStoreAndName() {
        let job = store.job(for: "dev")
        #expect(job.label.wholeMatch(of: /com\.hobo\.vm\.[0-9a-f]{8}\.dev/) != nil)
        let key = String(job.label.dropFirst(Launchd.labelPrefix.count))
        #expect(job.socket == store.home.root.appending(path: "\(key).sock"))
        #expect(job.log == store.home.root.appending(path: "\(key).log"))
        #expect(job.plist == store.home.root.appending(path: "launchd/\(key).plist"))

        let other = VMStore(directory: store.directory.appending(path: "other"), home: store.home, launchd: launchctl.launchd)
        #expect(other.job(for: "dev").label != job.label)
        #expect(store.job(for: "Dev").label != job.label)
    }

    @Test func jobKeyFollowsSymlinks() throws {
        // /tmp is a symlink to /private/tmp: one store, so one job.
        let name = "hobo-vms-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "/private/tmp/\(name)", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/private/tmp/\(name)") }
        let a = VMStore(directory: URL(filePath: "/tmp/\(name)"), home: store.home, launchd: launchctl.launchd)
        let b = VMStore(directory: URL(filePath: "/private/tmp/\(name)/"), home: store.home, launchd: launchctl.launchd)
        #expect(a.job(for: "dev") == b.job(for: "dev"))
    }

    @Test func runningAndCrashedComeFromTheJobTable() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for name in ["up", "down", "crashed", "killed", "unloaded"] { try made(name) }
        launchctl.list = """
        PID\tStatus\tLabel
        4242\t0\t\(store.job(for: "up").label)
        -\t0\t\(store.job(for: "down").label)
        -\t1\t\(store.job(for: "crashed").label)
        -\t-9\t\(store.job(for: "killed").label)
        """
        let statuses = Dictionary(uniqueKeysWithValues: store.list().map { ($0.name, $0.status) })
        #expect(statuses["up"] == .running(config, pid: 4242))
        #expect(statuses["down"] == .stopped(config))
        #expect(statuses["crashed"] == .crashed(config, exitStatus: 1))
        #expect(statuses["killed"] == .crashed(config, exitStatus: -9))
        #expect(statuses["unloaded"] == .stopped(config))
    }

    /// Gives `name` saved state, as a suspend leaves it: `bytes` of state and, unless nil, `run`.
    private func suspend(_ name: String, bytes: Int = 4096, run: SuspendedRun? = SuspendedRun(shares: [], suspendedAt: Date(timeIntervalSince1970: 1_800_000_100))) throws {
        let directory = SavedState.directory(in: store.bundle(for: name))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(repeating: 1, count: bytes).write(to: directory.appending(path: SavedState.stateFile))
        try run?.write(to: directory.appending(path: SavedState.runFile))
    }

    @Test func savedStateMakesAVMSuspendedUnlessItsProcessRuns() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for name in ["asleep", "resuming", "failedResume", "unreadable", "partial"] { try made(name) }
        for name in ["asleep", "resuming", "failedResume"] { try suspend(name) }
        try suspend("unreadable", run: nil)
        // A save that never finished leaves only `suspending/`, which doesn't count.
        try FileManager.default.createDirectory(at: SavedState.partialDirectory(in: store.bundle(for: "partial")), withIntermediateDirectories: false)
        launchctl.list = """
        PID\tStatus\tLabel
        4242\t0\t\(store.job(for: "resuming").label)
        -\t1\t\(store.job(for: "failedResume").label)
        """
        let statuses = Dictionary(uniqueKeysWithValues: store.list().map { ($0.name, $0.status) })
        let run = SuspendedRun(shares: [], suspendedAt: Date(timeIntervalSince1970: 1_800_000_100))
        guard case .suspended(config, let saved)? = statuses["asleep"] else { Issue.record("\(String(describing: statuses["asleep"]))"); return }
        #expect(saved.run == run && saved.bytes >= 4096)
        #expect(statuses["resuming"] == .running(config, pid: 4242))
        guard case .suspended(_, let failed)? = statuses["failedResume"] else { Issue.record("not suspended"); return }
        #expect(failed.run == run)
        guard case .suspended(_, let unreadable)? = statuses["unreadable"] else { Issue.record("not suspended"); return }
        #expect(unreadable.run == nil)
        #expect(statuses["partial"] == .stopped(config))
    }

    @Test func suspendedRunRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "run-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let run = SuspendedRun(
            shares: [VMShare(name: "src", path: "/Users/me/src", readOnly: true)], suspendedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        try run.write(to: file)
        #expect(try SuspendedRun.load(from: file) == run)
    }

    @Test func discardLeavesASuspendedVMStopped() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        try suspend("dev")
        #expect(try store.discard("dev"))
        #expect(try store.find("dev").status == .stopped(config))
        #expect(try !store.discard("dev"))
    }

    @Test func discardRefusesARunningVM() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        launchctl.list = "PID\tStatus\tLabel\n4242\t0\t\(store.job(for: "dev").label)\n"
        #expect(throws: VMStoreError.busy("dev", reason: "running (hobo stop dev)")) { try store.discard("dev") }
    }

    /// The default guard for anything that changes a VM's disk, configuration or platform identity
    /// (set, and later snapshot restore and clone): saved state fits only what it was saved with.
    @Test func checkStoppedRefusesASuspendedVMUnlessAllowed() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        try suspend("dev")
        let vm = try store.find("dev")
        #expect(throws: VMStoreError.busy("dev", reason: "suspended (hobo discard dev throws its saved state away)")) {
            try store.checkStopped(vm)
        }
        try store.checkStopped(vm, allowSuspended: true)
    }

    @Test func suspendedVMCanBeRenamedAndDeleted() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        try suspend("dev")
        try store.rename("dev", to: "exp")
        guard case .suspended = try store.find("exp").status else { Issue.record("the state didn't move with the bundle"); return }
        try store.delete("exp")
        #expect(store.list().isEmpty)
    }

    @Test func runningVMCannotBeDeletedOrRenamed() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        launchctl.list = "PID\tStatus\tLabel\n4242\t0\t\(store.job(for: "dev").label)\n"
        let busy = VMStoreError.busy("dev", reason: "running (hobo stop dev)")
        #expect(throws: busy) { try store.delete("dev") }
        #expect(throws: busy) { try store.rename("dev", to: "other") }
        #expect(!launchctl.calls.contains { $0.first == "bootout" })
    }

    @Test func runningJobBlocksDeleteEvenWithABrokenConfig() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        try Data("{".utf8).write(to: store.bundle(for: "dev").appending(path: VMStore.configFile))
        launchctl.list = "PID\tStatus\tLabel\n4242\t0\t\(store.job(for: "dev").label)\n"
        #expect(try store.find("dev").status == .broken)
        #expect(throws: VMStoreError.busy("dev", reason: "running (hobo stop dev)")) { try store.delete("dev") }
    }

    @Test(arguments: [false, true])
    func deleteAndRenameForgetTheOldJob(rename: Bool) throws {
        defer {
            try? FileManager.default.removeItem(at: store.directory)
            try? FileManager.default.removeItem(at: store.home.root)
        }
        try made("dev")
        let job = store.job(for: "dev")
        try FileManager.default.createDirectory(at: job.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [job.plist, job.log] { try Data("x".utf8).write(to: file) }

        if rename { try store.rename("dev", to: "exp") } else { try store.delete("dev") }
        #expect(launchctl.calls.contains(["bootout", "gui/\(getuid())/\(job.label)"]))
        #expect(!FileManager.default.fileExists(atPath: job.plist.path))
        #expect(!FileManager.default.fileExists(atPath: job.log.path))
    }

    @Test func summariesCarryEachStatesDetails() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for name in ["up", "crashed", "down", "asleep"] { try made(name) }
        try suspend("asleep", bytes: 8192)
        try orphaned("failed")
        _ = try store.beginCreate("building")
        launchctl.list = """
        PID\tStatus\tLabel
        4242\t0\t\(store.job(for: "up").label)
        -\t-9\t\(store.job(for: "crashed").label)
        """
        let summaries = Dictionary(uniqueKeysWithValues: store.list().map { ($0.name, VMSummary($0)) })
        #expect(summaries["up"]?.state == .running && summaries["up"]?.pid == 4242 && summaries["up"]?.config == config)
        #expect(summaries["crashed"]?.state == .crashed && summaries["crashed"]?.exitStatus == -9 && summaries["crashed"]?.pid == nil)
        #expect(summaries["down"]?.state == .stopped && summaries["down"]?.bundle == store.bundle(for: "down").path)
        #expect(summaries["down"]?.savedStateBytes == nil)
        #expect(summaries["asleep"]?.state == .suspended && summaries["asleep"]?.config == config)
        #expect((summaries["asleep"]?.savedStateBytes ?? 0) >= 8192)
        #expect(summaries["asleep"]?.suspendedAt == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(summaries["failed"]?.state == .failed && summaries["failed"]?.config == nil)
        #expect(summaries["building"]?.state == .building && summaries["building"]?.pid == getpid() && summaries["building"]?.config == nil)
    }

    @Test func summaryJSONUsesBytesAndISO8601() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        let line = String(decoding: try HoboJSON.line(store.list().map(VMSummary.init)), as: UTF8.self)
        #expect(!line.contains("\n"))
        #expect(line.contains(#""state":"stopped""#))
        #expect(line.contains(#""memory":8589934592"#))
        #expect(line.contains(#""created":"2027-01-15T08:00:00Z""#))
        #expect(!line.contains("pid"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([VMSummary].self, from: Data(line.utf8)) == store.list().map(VMSummary.init))
    }

    /// Copies what `cloneVM`'s copy does, without VZ: the platform files, and a new identifier.
    private func clone(_ source: String, to destination: String, ephemeral: Bool = false) throws -> VMStore.VM {
        try store.clone(source, to: destination, ephemeral: ephemeral, macAddress: "5a:00:00:00:00:02", log: { _ in }) { from, to, _ in
            try FileManager.default.copyItem(at: from.appending(path: "disk.asif"), to: to.appending(path: "disk.asif"))
            try Data("new".utf8).write(to: to.appending(path: "machine-identifier.bin"))
        }
    }

    /// A finished VM with a disk to clone.
    private func madeWithDisk(_ name: String) throws {
        try made(name)
        try Data("disk".utf8).write(to: store.bundle(for: name).appending(path: "disk.asif"))
    }

    @Test func cloneCopiesTheRecipeAndConfigWithANewMAC() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try madeWithDisk("dev")
        let source = store.bundle(for: "dev")
        try Data("old".utf8).write(to: source.appending(path: "machine-identifier.bin"))
        try Data("console".utf8).write(to: source.appending(path: "console.log"))

        let before = Date.now
        let vm = try clone("dev", to: "exp", ephemeral: true)
        guard case .stopped(let cloned) = vm.status else { Issue.record("not stopped: \(vm.status)"); return }
        #expect(cloned.macAddress == "5a:00:00:00:00:02")
        #expect(cloned.ephemeral)
        #expect(cloned.created >= before.addingTimeInterval(-1))
        var expected = cloned
        expected.macAddress = config.macAddress
        expected.created = config.created
        expected.ephemeral = false
        #expect(expected == config)
        #expect(try Data(contentsOf: vm.bundle.appending(path: VMStore.recipeFile)) == Data("cpus = 4\n".utf8))
        #expect(try Data(contentsOf: vm.bundle.appending(path: "disk.asif")) == Data("disk".utf8))
        #expect(try Data(contentsOf: vm.bundle.appending(path: "machine-identifier.bin")) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: vm.bundle.appending(path: "console.log").path))
        #expect(!FileManager.default.fileExists(atPath: vm.bundle.appending(path: VMStore.buildingMarker).path))
        // The source is untouched.
        #expect(try store.find("dev").status == .stopped(config))
    }

    @Test func cloneRefusesARunningOrSuspendedSourceAndATakenName() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for name in ["up", "asleep", "taken"] { try made(name) }
        try suspend("asleep")
        launchctl.list = "PID\tStatus\tLabel\n4242\t0\t\(store.job(for: "up").label)\n"
        #expect(throws: VMStoreError.busy("up", reason: "running (hobo stop up)")) { try clone("up", to: "exp") }
        #expect(throws: VMStoreError.busy("asleep", reason: "suspended (hobo discard asleep throws its saved state away)")) {
            try clone("asleep", to: "exp")
        }
        #expect(throws: VMStoreError.exists("up")) { try clone("taken", to: "UP") }
        #expect(throws: VMStoreError.invalidName("bad name")) { try clone("taken", to: "bad name") }
        #expect(store.list().map(\.name) == ["asleep", "taken", "up"])
    }

    /// Their netplan matches the source's MAC, so a clone with a new one would have no network.
    @Test func cloneRefusesALinuxVMThatMatchesItsNICByMAC() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var linux = config
        linux.os = .linux
        _ = try store.beginCreate("old")
        try store.finishCreate("old", config: linux, recipe: Data())
        linux.nicMatchedByDriver = true
        _ = try store.beginCreate("new")
        try store.finishCreate("new", config: linux, recipe: Data())
        try Data().write(to: store.bundle(for: "new").appending(path: "disk.asif"))

        #expect(throws: VMStoreError.notClonable(
            "old", "its guest finds its network card by MAC, so a clone would have no network; create it again to clone it"
        )) { try clone("old", to: "exp") }
        _ = try clone("new", to: "exp")
    }

    @Test func aCloneThatFailsIsDeleted() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        // No disk.asif to copy.
        #expect(throws: (any Error).self) { try clone("dev", to: "exp") }
        #expect(store.list().map(\.name) == ["dev"])
    }

    @Test func ephemeralNamesAreFreeAndFitTheNameLimit() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try made("dev")
        let name = try store.ephemeralName(for: "dev")
        #expect(name.wholeMatch(of: /dev-[0-9a-f]{4}/) != nil)
        let long = try store.ephemeralName(for: String(repeating: "a", count: 63))
        #expect(long.count == 63)
        try VMStore.validate(long)
    }

    /// What an ephemeral VM's process writes as it boots.
    private func markStarted(_ name: String) throws {
        try Data().write(to: store.bundle(for: name).appending(path: VMStore.startedMarker))
    }

    @Test(arguments: [false, true])
    func removeIfEphemeralDeletesTheBundleAndJobFilesAndTheLogUnlessKept(keepLog: Bool) throws {
        defer {
            try? FileManager.default.removeItem(at: store.directory)
            try? FileManager.default.removeItem(at: store.home.root)
        }
        try madeWithDisk("dev")
        _ = try clone("dev", to: "exp", ephemeral: true)
        let job = store.job(for: "exp")
        try FileManager.default.createDirectory(at: job.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [job.plist, job.socket, job.log] { try Data("x".utf8).write(to: file) }

        // Not until it has booted: `clone --ephemeral` leaves it stopped, waiting for a start.
        #expect(!store.removeIfEphemeral("exp", keepLog: keepLog))
        try markStarted("dev")
        try markStarted("exp")
        #expect(!store.removeIfEphemeral("dev", keepLog: keepLog))
        #expect(store.removeIfEphemeral("exp", keepLog: keepLog))
        #expect(store.list().map(\.name) == ["dev"])
        #expect(!FileManager.default.fileExists(atPath: job.plist.path))
        #expect(!FileManager.default.fileExists(atPath: job.socket.path))
        #expect(FileManager.default.fileExists(atPath: job.log.path) == keepLog)
    }

    /// A suspended ephemeral VM is kept until it is discarded and stopped.
    @Test func removeIfEphemeralKeepsASuspendedVM() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try madeWithDisk("dev")
        _ = try clone("dev", to: "exp", ephemeral: true)
        try markStarted("exp")
        try suspend("exp")
        #expect(!store.removeIfEphemeral("exp", keepLog: false))
        #expect(store.list().map(\.name) == ["dev", "exp"])
    }

    /// Whatever ended its run (a kill, a crash, a host reboot, a discard), an ephemeral VM that has
    /// booted and has no process is deleted when the store next reads it, keeping a crash's log.
    @Test func readingAStoppedOrCrashedEphemeralVMDeletesIt() throws {
        defer {
            try? FileManager.default.removeItem(at: store.directory)
            try? FileManager.default.removeItem(at: store.home.root)
        }
        try madeWithDisk("dev")
        for name in ["fresh", "up", "down", "crashed"] { _ = try clone("dev", to: name, ephemeral: true) }
        for name in ["up", "down", "crashed"] { try markStarted(name) }
        let downLog = store.job(for: "down").log, crashedLog = store.job(for: "crashed").log
        try FileManager.default.createDirectory(at: store.home.root, withIntermediateDirectories: true)
        for log in [downLog, crashedLog] { try Data("x".utf8).write(to: log) }
        launchctl.list = """
        PID\tStatus\tLabel
        4242\t0\t\(store.job(for: "up").label)
        -\t-9\t\(store.job(for: "crashed").label)
        """

        #expect(throws: VMStoreError.notFound("down")) { try store.find("down") }
        // Not yet booted, or still running: kept.
        #expect(store.list().map(\.name) == ["dev", "fresh", "up"])
        #expect(!FileManager.default.fileExists(atPath: downLog.path))
        #expect(FileManager.default.fileExists(atPath: crashedLog.path))
    }
}

/// Stands in for `launchctl`: `list` prints `list`, everything else succeeds silently, and every
/// call is recorded.
final class FakeLaunchctl: Sendable {
    private let state = Mutex<(list: String, calls: [[String]])>(("PID\tStatus\tLabel\n", []))

    var list: String {
        get { state.withLock { $0.list } }
        set { state.withLock { $0.list = newValue } }
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    var launchd: Launchd {
        Launchd { arguments in
            self.state.withLock { state in
                state.calls.append(arguments)
                return (0, arguments == ["list"] ? state.list : "")
            }
        }
    }
}
