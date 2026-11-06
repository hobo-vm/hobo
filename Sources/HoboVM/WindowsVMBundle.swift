import Foundation
import HoboCore
import Virtualization

/// The files that make up one Windows VM: an ASIF disk, the EFI variable store (which holds the
/// framebuffer driver's boot option) and a machine identifier.
public struct WindowsVMBundle: VMBundle {
    public static let platformFiles = ["disk.asif", "efi-vars.fd", "machine-identifier.bin"]
    public static let hiDPIDisplay = false
    /// viogpudo's startup mode, the only one that reaches the window intact: at the four larger sizes
    /// tried, Windows accepts the mode but the window goes almost black (Beads hobo-n64).
    public static let displayPixels = CGSize(width: 1024, height: 768)
    /// viogpudo doesn't follow the display, so the window scales this one instead.
    public static let displayFollowsWindow = false
    public static let ntpClockCommand: String? = nil
    public static func setClockCommand(_ date: Date) -> String { WindowsGuest.setClockCommand(date) }
    /// The share service's mount keeps working across a restore (checked 2026-11-05 on 11 build 26300).
    public static let remountSharesCommand: String? = nil
    public static let growDiskCommand = WindowsGuest.growDiskCommand
    public static let shutdownCommand = WindowsGuest.shutdownCommand
    public static func execLine(_ command: [String], marker: String) -> String { WindowsGuest.execLine(command, marker: marker) }
    public static func guiExecLine(_ command: [String], marker: String) -> String? { WindowsGuest.guiExecLine(command, marker: marker) }
    public static func cancelCommand(pid: Int32) -> String { WindowsGuest.cancelCommand(pid: pid) }

    public var directory: URL
    /// The install media, attached as USB storage while `create` installs.
    public var installMedia: URL?

    public init(directory: URL, installMedia: URL? = nil) {
        self.directory = directory
        self.installMedia = installMedia
    }

    public var disk: URL { directory.appending(path: "disk.asif") }
    public var efiVariables: URL { directory.appending(path: "efi-vars.fd") }
    public var machineIdentifier: URL { directory.appending(path: "machine-identifier.bin") }

    /// Creates an empty bundle ready for the install media.
    public static func create(at directory: URL, diskBytes: UInt64) throws -> WindowsVMBundle {
        let bundle = WindowsVMBundle(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runQuietly("/usr/sbin/diskutil", [
            "image", "create", "blank", "--format", "ASIF", "--fs", "None", "--size", String(diskBytes), bundle.disk.path,
        ])
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariables)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        return bundle
    }

    /// `diskutil image resize` gives the GPT a new disk GUID, which Windows' boot configuration names
    /// its disk by: without the old one it can't find itself, and powers off.
    public func keepingDiskIdentity(_ resize: () throws -> Void) throws {
        let guid = try withDiskDevice { device in try Self.readHeader(of: device, lba: Self.primaryHeaderLBA).diskGUID }
        try resize()
        try withDiskDevice { device in
            var primary = try Self.readHeader(of: device, lba: Self.primaryHeaderLBA)
            let backupLBA = primary.alternateLBA
            var backup = try Self.readHeader(of: device, lba: backupLBA)
            primary.diskGUID = guid
            backup.diskGUID = guid
            try Self.write(primary, to: device, lba: Self.primaryHeaderLBA)
            try Self.write(backup, to: device, lba: backupLBA)
        }
    }

    private static let sectorBytes: UInt64 = 512
    private static let primaryHeaderLBA: UInt64 = 1

    private func withDiskDevice<T>(_ body: (FileHandle) throws -> T) throws -> T {
        let attached = try output("/usr/sbin/diskutil", ["image", "attach", "--noMount", disk.path])
        guard let device = String(decoding: attached, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw VMError.unexpectedAttachOutput(disk.path)
        }
        defer { try? runQuietly("/usr/sbin/diskutil", ["eject", device]) }
        let handle = try FileHandle(forUpdating: URL(filePath: device))
        defer { try? handle.close() }
        return try body(handle)
    }

    private static func readHeader(of device: FileHandle, lba: UInt64) throws -> GPTHeader {
        try device.seek(toOffset: lba * sectorBytes)
        guard let header = GPTHeader(sector: try device.read(upToCount: Int(sectorBytes)) ?? Data()) else {
            throw VMError.diskHasNoGPT(lba)
        }
        return header
    }

    private static func write(_ header: GPTHeader, to device: FileHandle, lba: UInt64) throws {
        try device.seek(toOffset: lba * sectorBytes)
        try device.write(contentsOf: header.sector)
        try device.synchronize()
    }

    public func writeNewMachineIdentifier() throws {
        try VZGenericMachineIdentifier().dataRepresentation.write(to: machineIdentifier, options: .atomic)
    }

    /// NVMe, since Windows has a driver for it already; USB input for the same reason. `shares` go
    /// on one virtio-fs tag, which the guest mounts at `Z:\`, so each appears at `Z:\<name>`. The
    /// device is attached even with no shares, so the service mounting it always has one.
    public func configuration(
        cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress, shares: [VMShare]
    ) throws -> VZVirtualMachineConfiguration {
        guard let identifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIdentifier)) else {
            throw VMError.invalidMachineIdentifier
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = identifier
        try Self.enablePMUEmulation(on: platform)

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: efiVariables)

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: Int(Self.displayPixels.width), heightInPixels: Int(Self.displayPixels.height)
        )]

        var storage: [VZStorageDeviceConfiguration] = [VZNVMExpressControllerDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
        )]
        if let installMedia {
            // First, so that the firmware boots it rather than offering the empty disk. Writable,
            // since it's where the install script reports back.
            storage.insert(VZUSBMassStorageDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: installMedia, readOnly: false)
            ), at: 0)
        }

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = bootLoader
        config.cpuCount = cpus
        config.memorySize = memoryBytes
        config.graphicsDevices = [graphics]
        config.storageDevices = storage
        config.networkDevices = [natNetwork(macAddress: macAddress)]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.directorySharingDevices = [shareDevice(tag: Self.shareTag, shares: shares)]
        try config.validate()
        return config
    }

    static let shareTag = "hobo"

    /// Windows' boot loader spins forever without PMU emulation, which VZ only offers through a
    /// private setter (`spikes/windows-qemu/README.md`, finding 21; Beads hobo-9ni rechecks it).
    private static func enablePMUEmulation(on platform: VZGenericPlatformConfiguration) throws {
        let setter = NSSelectorFromString("_setPerformanceMonitoringUnitEmulationEnabled:")
        guard platform.responds(to: setter) else { throw VMError.windowsUnsupportedHere }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(platform.method(for: setter), to: Setter.self)(platform, setter, true)
    }
}
