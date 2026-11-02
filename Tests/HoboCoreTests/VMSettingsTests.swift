import Foundation
import Testing
@testable import HoboCore

@Suite struct VMSettingsTests {
    static let config = VMConfig(
        engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "aa:bb:cc:dd:ee:ff",
        guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 0), recipeSHA256: "r", sourceSHA256: "s"
    )
    static let limits = VMSettings.Limits(cpus: 1...10, memory: (1 << 30)...(32 << 30))

    @Test func changesOnlyTheGivenSettings() throws {
        let updated = try VMSettings(cpus: 6).applied(to: Self.config, limits: Self.limits)
        var expected = Self.config
        expected.cpus = 6
        #expect(updated == expected)
        #expect(try VMSettings(memory: ByteSize(bytes: 16 << 30)).applied(to: Self.config, limits: Self.limits).memory == 16 << 30)
    }

    @Test func emptyChangeIsRefused() {
        #expect(VMSettings().isEmpty)
        #expect(throws: VMSettingsError.nothingToChange) { try VMSettings().applied(to: Self.config, limits: Self.limits) }
    }

    @Test(arguments: [0, 11])
    func cpusOutsideTheHostLimitsAreRefused(cpus: Int) {
        #expect(throws: VMSettingsError.cpusOutOfRange(cpus, 1...10)) {
            try VMSettings(cpus: cpus).applied(to: Self.config, limits: Self.limits)
        }
    }

    @Test func memoryMustFitTheHostAndBeWholeMegabytes() {
        let tooBig = ByteSize(bytes: 64 << 30)
        #expect(throws: VMSettingsError.memoryOutOfRange(tooBig, Self.limits.memory)) {
            try VMSettings(memory: tooBig).applied(to: Self.config, limits: Self.limits)
        }
        let ragged = ByteSize(bytes: (2 << 30) + 512)
        #expect(throws: VMSettingsError.memoryNotWholeMegabytes(ragged)) {
            try VMSettings(memory: ragged).applied(to: Self.config, limits: Self.limits)
        }
    }

    @Test func growingTheDiskMarksTheContainerToGrow() throws {
        let updated = try VMSettings(disk: ByteSize(bytes: 100 << 30)).applied(to: Self.config, limits: Self.limits)
        #expect(updated.disk == 100 << 30)
        #expect(updated.diskGrowPending)
    }

    @Test func theSameDiskSizeChangesNothing() throws {
        let updated = try VMSettings(disk: ByteSize(bytes: 80 << 30)).applied(to: Self.config, limits: Self.limits)
        #expect(updated == Self.config)
    }

    /// A pending grow that hasn't happened yet survives a later set that doesn't touch the disk.
    @Test func aPendingGrowSurvivesOtherChanges() throws {
        var pending = Self.config
        pending.diskGrowPending = true
        #expect(try VMSettings(cpus: 2).applied(to: pending, limits: Self.limits).diskGrowPending)
        #expect(try VMSettings(disk: ByteSize(bytes: 80 << 30)).applied(to: pending, limits: Self.limits).diskGrowPending)
    }

    @Test func shrinkingTheDiskIsRefused() {
        #expect(throws: VMSettingsError.diskShrink(current: ByteSize(bytes: 80 << 30), requested: ByteSize(bytes: 60 << 30))) {
            try VMSettings(disk: ByteSize(bytes: 60 << 30)).applied(to: Self.config, limits: Self.limits)
        }
        #expect(VMSettingsError.diskShrink(current: ByteSize(bytes: 80 << 30), requested: ByteSize(bytes: 60 << 30)).description
            == "the disk can only grow (it is 80GB, asked for 60GB); the guest's freed space already returns to the host")
    }

    @Test func sharesAreAddedAfterUnsharing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hobo-settings-\(UUID().uuidString)")
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writable = VMShare(name: "src", path: src.path, readOnly: false)
        let readOnly = VMShare(name: "src", path: src.path, readOnly: true)

        let shared = try VMSettings(share: [writable]).applied(to: Self.config, limits: Self.limits)
        #expect(shared.shares == [writable])
        #expect(throws: VMShareError.duplicateName("src", src.path, src.path)) {
            try VMSettings(share: [readOnly]).applied(to: shared, limits: Self.limits)
        }
        #expect(try VMSettings(share: [readOnly], unshare: ["src"]).applied(to: shared, limits: Self.limits).shares == [readOnly])
        #expect(try VMSettings(unshare: [src.path]).applied(to: shared, limits: Self.limits).shares.isEmpty)
    }

    @Test func unknownUnsharesAndMissingFoldersAreRefused() {
        #expect(throws: VMShareError.unknown("nope")) { try VMSettings(unshare: ["nope"]).applied(to: Self.config, limits: Self.limits) }
        let missing = VMShare(name: "gone", path: "/nonexistent/gone", readOnly: false)
        #expect(throws: VMShareError.unusable("/nonexistent/gone", "it doesn't exist")) {
            try VMSettings(share: [missing]).applied(to: Self.config, limits: Self.limits)
        }
    }
}
