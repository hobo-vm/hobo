import Foundation
import HoboCore
import Virtualization

/// The files that make up one Linux VM: an ASIF disk converted from a cloud image, the EFI
/// variable store, and a machine identifier. The guest boots through EFI from the disk, and its
/// serial console goes to `console.log`, the only record of a boot that never reaches SSH.
public struct LinuxVMBundle: VMBundle {
    public static let platformFiles = ["disk.asif", "efi-vars.fd", "machine-identifier.bin"]

    public var directory: URL
    /// The cloud-init seed ISO, attached read-only as a second disk while `create` runs.
    public var seed: URL?

    public init(directory: URL, seed: URL? = nil) {
        self.directory = directory
        self.seed = seed
    }

    public var disk: URL { directory.appending(path: "disk.asif") }
    public var efiVariables: URL { directory.appending(path: "efi-vars.fd") }
    public var machineIdentifier: URL { directory.appending(path: "machine-identifier.bin") }
    public var consoleLog: URL { directory.appending(path: "console.log") }

    /// Creates the bundle from a cloud image (qcow2, or raw): converted to raw with `qemu-img`,
    /// then to ASIF, and grown to `diskBytes`. The guest grows its root filesystem on first boot.
    public static func create(at directory: URL, image: URL, diskBytes: UInt64, log: (String) -> Void) throws -> LinuxVMBundle {
        let bundle = LinuxVMBundle(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let qemuImg = try QEMUImg.locate()
        let imageBytes = try QEMUImg.virtualSize(of: image, tool: qemuImg)
        if diskBytes < imageBytes {
            throw VMError.diskTooSmall(wanted: diskBytes, image: imageBytes)
        }
        log("Converting the image to an ASIF disk")
        let raw = directory.appending(path: "disk.raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        try run(qemuImg, ["convert", "-O", "raw", image.path, raw.path])
        // Quietly: diskutil prints a progress counter.
        try runQuietly("/usr/sbin/diskutil", ["image", "create", "from", "--format", "ASIF", raw.path, bundle.disk.path])
        if diskBytes > imageBytes {
            // --image-only also moves the backup GPT to the new end; the guest's growpart does the rest.
            try runQuietly("/usr/sbin/diskutil", ["image", "resize", "--image-only", "--size", String(diskBytes), bundle.disk.path])
        }
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariables)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        return bundle
    }

    public func configuration(cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress) throws -> VZVirtualMachineConfiguration {
        guard let identifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIdentifier)) else {
            throw VMError.invalidMachineIdentifier
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = identifier

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: efiVariables)

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: Int(GuestDisplay.pixels.width), heightInPixels: Int(GuestDisplay.pixels.height)
        )]

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: consoleLog, append: false)

        // Cached + fsync: ext4 on VZ's default caching has been seen to corrupt (Lima, UTM). TRIM
        // still returns freed blocks to the ASIF, about 30 s after the guest's fstrim (2026-11-02).
        var storage: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
        )]
        if let seed {
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)))
        }

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = bootLoader
        config.cpuCount = cpus
        config.memorySize = memoryBytes
        config.graphicsDevices = [graphics]
        config.storageDevices = storage
        config.networkDevices = [natNetwork(macAddress: macAddress)]
        config.serialPorts = [console]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        try config.validate()
        return config
    }

    /// Writes the cloud-init seed for this VM as a `cidata` ISO in the bundle.
    public func writeSeed(vmName: String, macAddress: VZMACAddress) throws -> URL {
        let staging = directory.appending(path: "cidata")
        let iso = directory.appending(path: "cidata.iso")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (name, contents) in CloudInit.seed(vmName: vmName, macAddress: macAddress.string) {
            try contents.write(to: staging.appending(path: name), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: iso)
        _ = try output("/usr/bin/hdiutil", [
            "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", CloudInit.volumeName,
            "-o", iso.path, staging.path,
        ])
        return iso
    }
}

/// `qemu-img`, from Homebrew's QEMU, which converts cloud images (qcow2) to raw.
enum QEMUImg {
    static let candidates = ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img"]

    static func locate() throws -> String {
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/qemu-img" }
        guard let tool = (candidates + searchPath).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw VMError.missingQEMUImg
        }
        return tool
    }

    /// The size of the disk the image holds, as opposed to the file's size.
    static func virtualSize(of image: URL, tool: String) throws -> UInt64 {
        struct Info: Decodable {
            var virtualSize: UInt64
            enum CodingKeys: String, CodingKey { case virtualSize = "virtual-size" }
        }
        let json = try output(tool, ["info", "--output=json", image.path])
        return try JSONDecoder().decode(Info.self, from: json).virtualSize
    }
}
