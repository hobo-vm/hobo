import Foundation
import HoboControl
import HoboCore
import Virtualization

extension VMStore {
    /// `hobo clone <source> <destination> [--ephemeral]` (decision 12): an APFS clone of the
    /// stopped VM `source`, with a new machine identifier and MAC so both can run at once. The
    /// clone keeps the source's aux storage and hardware model, which it must: a macOS clone with
    /// fresh aux storage never boots.
    public func cloneVM(
        _ source: String, from sourceStore: VMStore? = nil, to destination: String, ephemeral: Bool = false, log: (String) -> Void
    ) throws -> VM {
        try clone(
            source, from: sourceStore, to: destination, ephemeral: ephemeral, macAddress: VZMACAddress.randomLocallyAdministered().string, log: log
        ) { from, to, config in
            try vmBundle(at: from, config: config).copyPlatformFiles(to: to)
            try vmBundle(at: to, config: config).writeNewMachineIdentifier()
        }
    }
}

extension VMLifecycle {
    /// `hobo start <source> --ephemeral`: clones the stopped VM `source` to a new, auto-named
    /// ephemeral VM (`VMStore.ephemeralName`) and starts that, returning its name. The clone is
    /// deleted when it stops, as it is if it fails to start. With no macOS slot free for it, it
    /// isn't cloned at all (`checkMacSlot`).
    public func startEphemeral(
        from source: String, gui: Bool = false, shares: [VMShare] = [], idleTimeout: IdleTimeout? = nil,
        timeout: Duration = .seconds(10 * 60)
    ) async throws -> (name: String, result: StartResult) {
        let vm = try store.find(source)
        // A source in any other state is the clone's to refuse.
        switch vm.status {
        case .stopped(let config), .crashed(let config, _): try checkMacSlot(for: config)
        default: break
        }
        let name = try store.ephemeralName(for: vm.name)
        _ = try store.cloneVM(vm.name, to: name, ephemeral: true, log: log)
        log("Cloned \(vm.name) to \(name)")
        do {
            return (name, try await start(name, gui: gui, shares: shares, idleTimeout: idleTimeout, timeout: timeout))
        } catch {
            // One that booted is deleted once it stops (finding it deletes it, `removeIfEphemeral`).
            // One that never booted is still here and deleted now: stopped (a bad share, say), or
            // crashed if its process died before marking it started (its `started` marker
            // unwritable on a full disk, say); the error already carries its log's tail.
            // One still booting after a timeout is left to run.
            switch try? store.find(name).status {
            case .stopped?, .crashed?: try? store.delete(name)
            default: break
            }
            throw error
        }
    }
}
