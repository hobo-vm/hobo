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
    func configuration(cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress) throws -> VZVirtualMachineConfiguration
}

extension VMBundle {
    /// Bytes the disk image actually occupies on the host.
    public func allocatedDiskBytes() -> UInt64 {
        let values = try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? 0)
    }
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
