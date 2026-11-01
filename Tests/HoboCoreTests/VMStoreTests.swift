import Foundation
import Testing
@testable import HoboCore

@Suite struct VMStoreTests {
    let store = VMStore(directory: FileManager.default.temporaryDirectory.appending(path: "hobo-vms-\(UUID().uuidString)"))
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
}
