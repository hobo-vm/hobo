import Foundation
import Testing
@testable import HoboAppModel
@testable import HoboCore

@Suite struct SettingsFormTests {
    static let config = VMConfig(
        os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "aa:bb:cc:dd:ee:ff",
        guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 0), recipeSHA256: "r", sourceSHA256: "s",
        shares: [VMShare(name: "src", path: "/src", readOnly: false), VMShare(name: "docs", path: "/docs", readOnly: true)]
    )

    @Test func anUneditedFormChangesNothing() {
        #expect(SettingsForm(Self.config).settings(from: Self.config).isEmpty)
    }

    @Test func eachEditBecomesTheSettingSetWouldGet() {
        var form = SettingsForm(Self.config)
        form.cpus = 6
        form.memoryGB = 16
        form.diskGB = 120
        #expect(form.settings(from: Self.config) == VMSettings(
            cpus: 6, memory: ByteSize(bytes: 16 << 30), disk: ByteSize(bytes: 120 << 30)
        ))
    }

    @Test func aShareEditedInPlaceIsRemovedAndAddedAgain() {
        var form = SettingsForm(Self.config)
        form.shares[0].readOnly = true
        form.shares.remove(at: 1)
        form.shares.append(VMShare(name: "music", path: "/music", readOnly: false))
        let settings = form.settings(from: Self.config)
        #expect(settings.removeShares == ["src", "docs"])
        #expect(settings.addShares == [VMShare(name: "src", path: "/src", readOnly: true), VMShare(name: "music", path: "/music", readOnly: false)])
    }

    @Test func memoryInMegabytesStaysUnlessEdited() {
        var config = Self.config
        config.memory = 6000 << 20
        let form = SettingsForm(config)
        #expect(form.memoryGB == 6)
        #expect(form.settings(from: config).memory == nil)
    }

    @Test func keepOnlyAppliesToAnEphemeralVM() {
        var ephemeral = Self.config
        ephemeral.ephemeral = true
        var form = SettingsForm(ephemeral)
        #expect(!form.keep && form.settings(from: ephemeral).isEmpty)
        form.keep = true
        #expect(form.settings(from: ephemeral) == VMSettings(keep: true))
        #expect(SettingsForm(Self.config).keep)
    }

    static func summary(_ status: VMStore.Status) -> VMSummary {
        VMSummary(VMStore.VM(name: "dev", bundle: URL(filePath: "/tmp/dev.hobovm"), status: status, allocatedBytes: 0, job: nil))
    }

    @Test func onlyAStoppedVMsMachineCanBeEdited() {
        #expect(SettingsForm.editable(Self.summary(.stopped(Self.config))) == .init(machine: true, keep: true))
        #expect(SettingsForm.editable(Self.summary(.crashed(Self.config, exitStatus: 1))).machine)
        let running = SettingsForm.editable(Self.summary(.running(Self.config, pid: 1)))
        #expect(!running.machine && running.keep && running.reason == "Stop dev to change these.")
        let suspended = SettingsForm.editable(Self.summary(.suspended(Self.config, SavedState(bytes: 1, run: nil))))
        #expect(!suspended.machine && suspended.keep)
        #expect(SettingsForm.editable(Self.summary(.building(pid: 1))) == .init(machine: false, keep: false, reason: "dev is being built."))
        #expect(!SettingsForm.editable(Self.summary(.broken)).keep)
    }
}
