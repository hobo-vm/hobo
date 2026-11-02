import Foundation
import HoboCore
import Virtualization

/// One running `VZVirtualMachine`, driven from the main actor (VZ's default queue).
@MainActor
public final class GuestVM {
    public let bundle: any VMBundle
    public let macAddress: VZMACAddress
    let machine: VZVirtualMachine
    private let observer = StopObserver()

    public init(bundle: any VMBundle, cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress, shares: [VMShare] = []) throws {
        self.bundle = bundle
        self.macAddress = macAddress
        machine = VZVirtualMachine(configuration: try bundle.configuration(
            cpus: cpus, memoryBytes: memoryBytes, macAddress: macAddress, shares: shares
        ))
        machine.delegate = observer
    }

    /// Called when the guest powers itself off (nil) or the VM stops with an error. Not called
    /// for `forceStop`, whose caller already knows.
    public var onStop: ((Error?) -> Void)? {
        get { observer.onStop }
        set { observer.onStop = newValue }
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

    /// Boots the guest.
    public func start() async throws {
        try await machine.start()
    }

    /// Boots a macOS guest, into recoveryOS with `recovery`. `provisioning` only takes effect on
    /// the first boot after restore.
    public func start(provisioning: VZMacGuestProvisioningOptions?, recovery: Bool = false) async throws {
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = recovery
        if let provisioning { try options.setGuestProvisioning(provisioning) }
        try await machine.start(options: options)
    }

    public func pause() async throws { try await machine.pause() }

    public func resume() async throws { try await machine.resume() }

    /// Saves a paused VM's memory and device state.
    public func saveState(to url: URL) async throws { try await machine.saveMachineStateTo(url: url) }

    /// Restores state saved by `saveState` into a VM that hasn't started; it is left paused. VZ
    /// refuses state saved under another configuration.
    public func restoreState(from url: URL) async throws { try await machine.restoreMachineStateFrom(url: url) }

    /// Powered off or crashed: either way there is no guest left to reach.
    public var isStopped: Bool { machine.state == .stopped || machine.state == .error }

    /// Waits for the guest to power itself off; forces it off after `timeout`.
    /// Returns false if it had to be forced.
    @discardableResult
    public func waitForPowerOffOrForce(timeout: Duration) async throws -> Bool {
        if try await waitForPowerOff(timeout: timeout) { return true }
        try await forceStop()
        return false
    }

    /// Waits up to `timeout` for the guest to power itself off. Returns false if it is still on.
    public func waitForPowerOff(timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch machine.state {
            case .stopped: return true
            case .error: throw VMError.stoppedWithError
            default: try await Task.sleep(for: .seconds(1))
            }
        }
        return false
    }

    /// Asks the guest to shut down, like pressing the power button. A macOS guest may only show
    /// a dialog, so callers follow up. Returns false if VZ can't send the request now.
    public func requestStop() -> Bool {
        guard machine.canRequestStop else { return false }
        return (try? machine.requestStop()) != nil
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

/// Forwards VZ's stop callbacks, which arrive on the VM's queue (the main queue).
@MainActor
private final class StopObserver: NSObject, @MainActor VZVirtualMachineDelegate {
    var onStop: ((Error?) -> Void)?

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStop?(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        onStop?(error)
    }
}
