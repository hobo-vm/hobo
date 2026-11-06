import Foundation
import HoboCore
import Virtualization

extension VMSettings.Limits {
    /// The Virtualization framework's limits on this host.
    public static var host: Self {
        Self(
            cpus: VZVirtualMachineConfiguration.minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            memory: VZVirtualMachineConfiguration.minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
    }
}

extension VMSettings {
    /// `hobo set`: changes a VM's `config.json`, growing its disk image first if asked. The guest's
    /// filesystem grows into the new space at the next boot (`VMRunner`). Only `keep` applies to a
    /// running or suspended VM; its VM process reads `config.json` again as it exits.
    public func apply(to name: String, store: VMStore = .standard(), log: @Sendable (String) -> Void) throws -> VMConfig {
        let vm = try store.find(name)
        if changesMachine {
            // Also refuses a VM process still running from a bundle whose config.json has gone bad.
            try store.checkStopped(vm)
        } else if case .building = vm.status {
            throw VMStoreError.busy(vm.name, reason: "being built")
        }
        let config: VMConfig
        switch vm.status {
        case .stopped(let stored), .crashed(let stored, _): config = stored
        case .running(let stored, _), .suspended(let stored, _):
            precondition(!changesMachine, "checkStopped refuses a running or suspended VM")
            config = stored
        case .building: preconditionFailure("refused above")
        case .failed: throw VMSettingsError.notConfigurable(vm.name, "its build failed (hobo delete \(vm.name))")
        case .broken: throw VMSettingsError.notConfigurable(vm.name, "its bundle has no valid \(VMStore.configFile)")
        }
        let updated = try applied(to: config, limits: .host)
        if updated.disk > config.disk {
            log("Growing the disk image to \(ByteSize(bytes: updated.disk))")
            // Moves what ends the disk (a macOS guest's Recovery container, a Linux guest's backup
            // GPT) to the new end, so the free space follows the partition the guest grows.
            let bundle = try vmBundle(at: vm.bundle, os: config.os)
            try bundle.keepingDiskIdentity {
                try run("/usr/sbin/diskutil", ["image", "resize", "--image-only", "--size", String(updated.disk), bundle.disk.path])
            }
        }
        try updated.write(to: vm.bundle.appending(path: VMStore.configFile))
        return updated
    }
}
