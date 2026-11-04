import Foundation
import HoboCore
import Virtualization

/// The files that make up one VM on the Virtualization framework, and the VZ configuration to boot
/// them: `MacVMBundle` for a macOS guest, `LinuxVMBundle` for a Linux one. Everything else (the
/// create pipeline, the VM process, the window) works on any bundle.
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
    /// Sets a resumed guest's clock over NTP, if the guest has a one-shot command for it; the VM
    /// process falls back to `setClockCommand` when this is nil or fails.
    static var ntpClockCommand: String? { get }
    /// Sets the guest's clock to `date`, the host's time.
    static func setClockCommand(_ date: Date) -> String
    /// Replaces the guest's share mount after a resume, or nil if its mount survives a restore.
    static var remountSharesCommand: String? { get }
    /// Grows the guest's root filesystem, live, into a disk `hobo set --disk` enlarged. It runs
    /// again at the next start if it fails, so it must be safe to repeat.
    static var growDiskCommand: String { get }
    /// Gives the bundle a new machine identifier, so a clone and its source can run side by side.
    func writeNewMachineIdentifier() throws
    func configuration(
        cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress, shares: [VMShare]
    ) throws -> VZVirtualMachineConfiguration
}

extension VMBundle {
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
public func vmBundle(at directory: URL, os: VMConfig.OS) throws -> any VMBundle {
    switch os {
    case .macOS: MacVMBundle(directory: directory)
    case .linux: LinuxVMBundle(directory: directory)
    case .windows: throw VMError.unsupportedOS(os)
    }
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
