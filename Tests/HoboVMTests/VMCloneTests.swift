import Foundation
import HoboControl
import HoboCore
import Synchronization
import Testing
@testable import HoboVM

/// `hobo clone` and `start --ephemeral` against a store with a fake launchd and stand-in platform
/// files. Needs no VM, so it runs without HOBO_INTEGRATION.
@Suite struct VMCloneTests {
    let store: VMStore
    let config = VMConfig(
        engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
        guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 1_800_000_000),
        recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
    )

    init() throws {
        let temp = FileManager.default.temporaryDirectory
        store = VMStore(
            directory: temp.appending(path: "hobo-vms-\(UUID().uuidString)"),
            home: HoboHome(root: temp.appending(path: "hobo-home-\(UUID().uuidString)")),
            launchd: Launchd { arguments in (0, arguments == ["list"] ? "PID\tStatus\tLabel\n" : "") }
        )
        _ = try store.beginCreate("dev")
        for name in MacVMBundle.platformFiles {
            try Data(name.utf8).write(to: store.bundle(for: "dev").appending(path: name))
        }
        try store.finishCreate("dev", config: config, recipe: Data())
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: store.directory)
        try? FileManager.default.removeItem(at: store.home.root)
    }

    /// Every platform file is copied except the machine identifier, which is new.
    @Test func cloneCopiesThePlatformFilesWithANewMachineIdentifier() throws {
        defer { cleanUp() }
        let vm = try store.cloneVM("dev", to: "exp") { _ in }
        let source = store.bundle(for: "dev")
        for name in MacVMBundle.platformFiles {
            let copied = try Data(contentsOf: vm.bundle.appending(path: name))
            if name == "machine-identifier.bin" {
                #expect(copied != Data(name.utf8))
            } else {
                #expect(try copied == Data(contentsOf: source.appending(path: name)), "\(name)")
            }
        }
        guard case .stopped(let cloned) = vm.status else { Issue.record("not stopped: \(vm.status)"); return }
        #expect(cloned.macAddress != config.macAddress && !cloned.ephemeral)
    }

    /// A clone whose VM process never ran can't delete itself, so `startEphemeral` does.
    @Test func anEphemeralCloneThatFailsToStartIsDeleted() async throws {
        defer { cleanUp() }
        let missing = VMShare(name: "gone", path: "/nonexistent-\(UUID().uuidString)", readOnly: false)
        await #expect(throws: (any Error).self) {
            _ = try await VMLifecycle(store: store) { _ in }.startEphemeral(from: "dev", shares: [missing])
        }
        #expect(store.list().map(\.name) == ["dev"])
    }
}
