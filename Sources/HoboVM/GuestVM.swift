import Foundation
import HoboCore
import Virtualization

/// One running `VZVirtualMachine`, driven from the main actor (VZ's default queue).
@MainActor
public final class GuestVM {
    public let bundle: MacVMBundle
    public let macAddress: VZMACAddress
    let machine: VZVirtualMachine

    public init(bundle: MacVMBundle, cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress) throws {
        self.bundle = bundle
        self.macAddress = macAddress
        machine = VZVirtualMachine(configuration: try bundle.configuration(cpus: cpus, memoryBytes: memoryBytes, macAddress: macAddress))
    }

    /// Restores `ipsw` onto the bundle's empty disk.
    public func install(ipsw: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: ipsw)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
            progress(change.newValue ?? 0)
        }
        defer { observation.invalidate() }
        try await installer.install()
    }

    /// Boots the guest. `provisioning` only takes effect on the first boot after restore.
    public func start(provisioning: VZMacGuestProvisioningOptions? = nil) async throws {
        let options = VZMacOSVirtualMachineStartOptions()
        if let provisioning { try options.setGuestProvisioning(provisioning) }
        try await machine.start(options: options)
    }

    /// Powered off or crashed: either way there is no guest left to reach.
    public var isStopped: Bool { machine.state == .stopped || machine.state == .error }

    /// Waits for the guest to power itself off; forces it off after `timeout`.
    /// Returns false if it had to be forced.
    @discardableResult
    public func waitUntilStopped(timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch machine.state {
            case .stopped: return true
            case .error: throw VMError.stoppedWithError
            default: try await Task.sleep(for: .seconds(1))
            }
        }
        try await forceStop()
        return false
    }

    /// No-op once stopped, or in states VZ can't stop from (e.g. `.error`), where `stop()` would
    /// throw and hide the failure that got us here.
    public func forceStop() async throws {
        if machine.state != .stopped, machine.canStop { try await machine.stop() }
    }

    /// Polls the DHCP leases for this VM's address.
    public func waitForIPAddress(timeout: Duration) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let ip = DHCPLeases.ipAddress(forMAC: macAddress.string) { return ip }
            try await Task.sleep(for: .seconds(2))
        }
        throw VMError.timedOut("waiting for a DHCP lease for \(macAddress.string)")
    }
}
