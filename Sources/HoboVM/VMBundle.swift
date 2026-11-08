import Foundation
import HoboCore
import Virtualization

/// The files that make up one VM on the Virtualization framework, and the VZ configuration to boot
/// them: `MacVMBundle` for a macOS guest, `LinuxVMBundle` for a Linux one, `WindowsVMBundle` for a
/// Windows one. Everything else (the create pipeline, the VM process, the window) works on any bundle.
public protocol VMBundle: Sendable {
    var directory: URL { get }
    /// The guest's disk, always ASIF, so freed blocks return to the host.
    var disk: URL { get }
    /// The files a clone or snapshot copies.
    static var platformFiles: [String] { get }
    /// Whether the window gives the guest a display in Retina pixels. A guest that doesn't scale
    /// its UI by itself (Linux's text console and default desktop) gets one in points instead, so
    /// its text isn't half size; the window scales it up.
    static var hiDPIDisplay: Bool { get }
    /// The guest display's size, in pixels, while no window has resized it.
    var displayPixels: CGSize { get }
    /// Whether the guest display resizes to the window showing it. False keeps the configured size,
    /// which the window scales.
    var displayFollowsWindow: Bool { get }
    /// The smallest window, in points, whose size the guest display still follows, or nil if it has
    /// no floor. A smaller window would only scale down the guest's smallest mode, so the window is
    /// kept from shrinking past it.
    static var smallestFollowedWindow: CGSize? { get }
    /// Sets a resumed guest's clock over NTP, if the guest has a one-shot command for it; the VM
    /// process falls back to `setClockCommand` when this is nil or fails.
    static var ntpClockCommand: String? { get }
    /// Sets the guest's clock to `date`, the host's time.
    static func setClockCommand(_ date: Date) -> String
    /// Brings the guest's share mount up to date after a resume (replacing it, or dropping what it
    /// has cached), or nil if it needs nothing.
    static var remountSharesCommand: String? { get }
    /// Grows the guest's root filesystem, live, into a disk `hobo set --disk` enlarged. It runs
    /// again at the next start if it fails, so it must be safe to repeat.
    static var growDiskCommand: String { get }
    /// Shuts the guest down.
    static var shutdownCommand: String { get }
    /// The line hobo-agent runs in the user's shell for `hobo exec` of `command`, in the desktop
    /// session if `gui`: getting there itself, unless `agentStartsInDesktop`. In the desktop
    /// session it waits up to `GUISession.waitSeconds` for it, since auto-login can finish after
    /// the agent answers, and exits `GUISession.unavailableStatus` if it never comes up.
    static func agentCommand(_ command: [String], gui: Bool) -> String
    /// Whether hobo-agent starts an `exec --gui` command in the desktop session itself (Windows,
    /// where the agent is a SYSTEM process in session 0), rather than `agentCommand`'s line.
    static var agentStartsInDesktop: Bool { get }
    /// Runs `resize`, which rewrites the disk's partition table, leaving whatever the guest's boot
    /// depends on as it was.
    func keepingDiskIdentity(_ resize: () throws -> Void) throws
    /// Gives the bundle a new machine identifier, so a clone and its source can run side by side.
    func writeNewMachineIdentifier() throws
    func configuration(
        cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress, shares: [VMShare]
    ) throws -> VZVirtualMachineConfiguration
}

/// A POSIX shell's way of doing these, which macOS and Linux guests share.
extension VMBundle {
    public static var shutdownCommand: String { "sudo -n shutdown -h now" }
    public static var agentStartsInDesktop: Bool { false }
}

extension VMBundle {
    public var displayPixels: CGSize { GuestDisplay.pixels }
    public var displayFollowsWindow: Bool { true }
    public static var smallestFollowedWindow: CGSize? { nil }

    /// macOS and Linux guests don't care what `resize` does to the table's identity.
    public func keepingDiskIdentity(_ resize: () throws -> Void) throws { try resize() }

    /// Bytes the disk image actually occupies on the host.
    public func allocatedDiskBytes() -> UInt64 {
        let values = try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? 0)
    }

    /// Copies `platformFiles` into `destination`, as APFS clones where it can (instant, and free
    /// until either copy changes a block), otherwise as full copies.
    func copyPlatformFiles(to destination: URL) throws {
        for name in Self.platformFiles {
            try cloneFile(directory.appending(path: name), to: destination.appending(path: name))
        }
    }
}

/// Copies a file as an APFS clone where it can, otherwise in full. Fails if `target` exists.
func cloneFile(_ source: URL, to target: URL) throws {
    guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
        throw VMError.cloneFailed(source.lastPathComponent, String(cString: strerror(errno)))
    }
}

/// Exits 0 if the guest's clock is within 2 s of `date`, the host's time. POSIX sh, for any guest.
func clockAgreesCommand(_ date: Date) -> String {
    let difference = "$(( $(date +%s) - \(Int(date.timeIntervalSince1970)) ))"
    return "d=\(difference); [ \"$d\" -ge -2 ] && [ \"$d\" -le 2 ]"
}

/// The bundle a VM's `config.json` says it has.
public func vmBundle(at directory: URL, config: VMConfig) throws -> any VMBundle {
    switch config.os {
    case .macOS: MacVMBundle(directory: directory)
    case .linux: LinuxVMBundle(directory: directory)
    case .windows: WindowsVMBundle(directory: directory, resizableDisplay: config.resizableDisplay)
    }
}

/// What every guest's `exec --gui` does when the desktop session isn't there.
enum GUISession {
    /// How long it waits for the session, which auto-login can finish after SSH answers.
    static let waitSeconds = 60
    /// What it exits with when the session never comes up, like `env` failing to run a command.
    static let unavailableStatus: Int32 = 125
}

/// The guest display's configured size. A window resizes it while showing (`VMWindow`), and
/// hiding the window puts it back, so headless runs always see this.
enum GuestDisplay {
    static let pixels = CGSize(width: 1920, height: 1200)
}

/// A shared NAT network device with the VM's fixed MAC (decision 16).
func natNetwork(macAddress: VZMACAddress) -> VZVirtioNetworkDeviceConfiguration {
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    network.macAddress = macAddress
    return network
}

/// A virtio-fs device on `tag` holding every share, each a directory named after it (decision 9).
func shareDevice(tag: String, shares: [VMShare]) -> VZVirtioFileSystemDeviceConfiguration {
    let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
    device.share = VZMultipleDirectoryShare(directories: Dictionary(uniqueKeysWithValues: shares.map { share in
        (share.name, VZSharedDirectory(url: URL(filePath: share.path, directoryHint: .isDirectory), readOnly: share.readOnly))
    }))
    return device
}
