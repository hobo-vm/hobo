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
        for name in ["up", "crashed", "down"] { try made(name) }
        try orphaned("failed")
        launchctl.list = """
        PID\tStatus\tLabel
        4242\t0\t\(store.job(for: "up").label)
        -\t-9\t\(store.job(for: "crashed").label)
        """
        let summaries = Dictionary(uniqueKeysWithValues: store.list().map { ($0.name, VMSummary($0)) })
        #expect(summaries["up"]?.state == .running && summaries["up"]?.pid == 4242 && summaries["up"]?.config == config)
        #expect(summaries["crashed"]?.state == .crashed && summaries["crashed"]?.exitStatus == -9 && summaries["crashed"]?.pid == nil)
        #expect(summaries["down"]?.state == .stopped && summaries["down"]?.bundle == store.bundle(for: "down").path)
        #expect(summaries["failed"]?.state == .failed && summaries["failed"]?.config == nil)
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
