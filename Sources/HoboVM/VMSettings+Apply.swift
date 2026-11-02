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
    /// `hobo set`: changes a stopped VM's `config.json`, growing its disk image first if asked.
    /// The guest's APFS container grows into the new space at the next boot (`VMRunner`).
    public func apply(to name: String, store: VMStore = .standard(), log: @Sendable (String) -> Void) throws -> VMConfig {
        let vm = try store.find(name)
        // Also refuses a VM process still running from a bundle whose config.json has gone bad.
        try store.checkStopped(vm)
        let config: VMConfig
        switch vm.status {
        case .stopped(let stored), .crashed(let stored, _): config = stored
        case .running, .building, .suspended:
            preconditionFailure("checkStopped refuses a running, building or suspended VM")
        case .failed: throw VMSettingsError.notConfigurable(vm.name, "its build failed (hobo delete \(vm.name))")
        case .broken: throw VMSettingsError.notConfigurable(vm.name, "its bundle has no valid \(VMStore.configFile)")
        }
        let updated = try applied(to: config, limits: .host)
        if updated.disk > config.disk {
            log("Growing the disk image to \(ByteSize(bytes: updated.disk))")
            // Moves the trailing Recovery container to the new end, so the free space follows the
            // main container, which the guest then grows into.
            try run("/usr/sbin/diskutil", [
                "image", "resize", "--image-only", "--size", String(updated.disk),
                MacVMBundle(directory: vm.bundle).disk.path,
            ])
        }
        try updated.write(to: vm.bundle.appending(path: VMStore.configFile))
        return updated
    }
}
