import Foundation
import HoboCore
import Synchronization
import Testing
@testable import HoboVM

/// `hobo set` against a store with a fake launchd: which VMs it refuses, and that a change that
/// leaves the disk alone only rewrites `config.json`. Needs no VM, so it runs without HOBO_INTEGRATION.
@Suite struct VMSettingsApplyTests {
    /// What the fake `launchctl list` prints: no jobs until a test adds one.
    final class JobList: Sendable {
        let value = Mutex("PID\tStatus\tLabel\n")
    }

    let jobs = JobList()
    let store: VMStore
    let config = VMConfig(
        engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
        guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 1_800_000_000),
        recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
    )

    init() {
        let temp = FileManager.default.temporaryDirectory
        let directory = temp.appending(path: "hobo-vms-\(UUID().uuidString)")
        let home = HoboHome(root: temp.appending(path: "hobo-home-\(UUID().uuidString)"))
        store = VMStore(directory: directory, home: home, launchd: Launchd { [jobs] arguments in
            (0, arguments == ["list"] ? jobs.value.withLock { $0 } : "")
        })
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: store.directory)
    }

    @Test func aStoppedVMsConfigIsRewritten() throws {
        defer { cleanUp() }
        _ = try store.beginCreate("dev")
        try store.finishCreate("dev", config: config, recipe: Data())
        let updated = try VMSettings(cpus: 2, memory: ByteSize(bytes: 4 << 30)).apply(to: "dev", store: store) { _ in }
        #expect(updated.cpus == 2 && updated.memory == 4 << 30 && !updated.diskGrowPending)
        #expect(try store.find("dev").status == .stopped(updated))
    }

    @Test func aRunningVMIsRefused() throws {
        defer { cleanUp() }
        _ = try store.beginCreate("dev")
        try store.finishCreate("dev", config: config, recipe: Data())
        let label = store.job(for: "dev").label
        jobs.value.withLock { $0 += "4242\t0\t\(label)\n" }
        #expect(throws: VMStoreError.busy("dev", reason: "running (hobo stop dev)")) {
            try VMSettings(cpus: 2).apply(to: "dev", store: store) { _ in }
        }
    }

    @Test func aFailedBuildIsRefused() throws {
        defer { cleanUp() }
        let bundle = try store.beginCreate("dev")
        // A marker older than this live process names a builder that has since died.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: bundle.appending(path: VMStore.buildingMarker).path
        )
        #expect(throws: VMSettingsError.notConfigurable("dev", "its build failed (hobo delete dev)")) {
            try VMSettings(cpus: 2).apply(to: "dev", store: store) { _ in }
        }
    }

    @Test func aBrokenBundleIsRefused() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: store.bundle(for: "dev"), withIntermediateDirectories: true)
        #expect(throws: VMSettingsError.notConfigurable("dev", "its bundle has no valid \(VMStore.configFile)")) {
            try VMSettings(cpus: 2).apply(to: "dev", store: store) { _ in }
        }
    }
}
