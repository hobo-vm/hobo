import Foundation
import HoboCore
import Virtualization

/// The files that make up one Linux VM: an ASIF disk converted from a cloud image, the EFI
/// variable store, and a machine identifier. The guest boots through EFI from the disk, and its
/// serial console goes to `console.log`, the only record of a boot that never reaches SSH.
public struct LinuxVMBundle: VMBundle {
    public static let platformFiles = ["disk.asif", "efi-vars.fd", "machine-identifier.bin"]
    public static let hiDPIDisplay = false
    /// chrony would slew a long suspension away only slowly, so the host's time is set instead.
    public static let ntpClockCommand: String? = nil
    /// Seconds since the epoch: Ubuntu's uutils `date` rejects the `mmddHHMMccyy.ss` form
    /// (checked 2026-11-02 on 26.04), and GNU's takes this too.
    public static func setClockCommand(_ date: Date) -> String {
        "sudo -n date -u -s @\(String(format: "%.3f", date.timeIntervalSince1970)) >/dev/null"
    }
    /// The guest's virtio-fs mount keeps working across a restore: after a resume it sees files
    /// the host added and writes through (checked 2026-11-02 on Ubuntu 26.04).
    public static let remountSharesCommand: String? = nil
    /// Grows the root partition to the end of the disk, then its ext4 filesystem, both live:
    /// cloud-init's growpart did this at create but is off afterwards. growpart exits 1 when the
    /// partition already fills the disk, as on a retry after `resize2fs` failed.
    public static let growDiskCommand = #"root=$(findmnt -no SOURCE /) && part=$(cat "/sys/class/block/${root#/dev/}/partition") && { sudo -n growpart "/dev/$(lsblk -no PKNAME "$root")" "$part" || [ $? -eq 1 ]; } && sudo -n resize2fs "$root""#
    /// Linux GUI testing waits on its own design (Beads hobo-938).
    public static func guiExecScript(_ command: [String]) -> String? { nil }

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
        let info = try QEMUImg.info(of: image, tool: qemuImg)
        if diskBytes < info.virtualSize {
            throw VMError.diskTooSmall(wanted: diskBytes, image: info.virtualSize)
        }
        log("Converting the image to an ASIF disk")
        let raw = directory.appending(path: "disk.raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        // The format as inspected, so qemu-img doesn't probe it again.
        try run(qemuImg, ["convert", "-f", info.format, "-O", "raw", image.path, raw.path])
        // Quietly: diskutil prints a progress counter.
        try runQuietly("/usr/sbin/diskutil", ["image", "create", "from", "--format", "ASIF", raw.path, bundle.disk.path])
        if diskBytes > info.virtualSize {
            // --image-only also moves the backup GPT to the new end; the guest's growpart does the rest.
            try runQuietly("/usr/sbin/diskutil", ["image", "resize", "--image-only", "--size", String(diskBytes), bundle.disk.path])
        }
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariables)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        return bundle
    }

    public func writeNewMachineIdentifier() throws {
        try VZGenericMachineIdentifier().dataRepresentation.write(to: machineIdentifier, options: .atomic)
    }

    /// `shares` go on one virtio-fs tag, which the guest's fstab (from the cloud-init seed) mounts
    /// at `/mnt/hobo`, so each appears at `/mnt/hobo/<name>`. The device is attached even with no
    /// shares, so the mount never fails and nothing written there lands on the guest's disk.
    public func configuration(
        cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress, shares: [VMShare]
    ) throws -> VZVirtualMachineConfiguration {
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
        config.directorySharingDevices = [shareDevice(tag: CloudInit.shareTag, shares: shares)]
        try config.validate()
        return config
    }

    /// Writes the cloud-init seed for this VM as a `cidata` ISO in the bundle.
    public func writeSeed(vmName: String) throws -> URL {
        let staging = directory.appending(path: "cidata")
        let iso = directory.appending(path: "cidata.iso")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (name, contents) in CloudInit.seed(vmName: vmName, uid: getuid()) {
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

    /// What `qemu-img info` says about an image.
    struct Info: Decodable, Equatable {
        var format: String
        /// The size of the disk the image holds, as opposed to the file's size.
        var virtualSize: UInt64
        var backingFilename: String?
        var formatSpecific: FormatSpecific?

        struct FormatSpecific: Decodable, Equatable {
            var data: Fields?
            struct Fields: Decodable, Equatable {
                var dataFile: String?
                enum CodingKeys: String, CodingKey { case dataFile = "data-file" }
            }
        }

        enum CodingKeys: String, CodingKey {
            case format
            case virtualSize = "virtual-size"
            case backingFilename = "backing-filename"
            case formatSpecific = "format-specific"
        }
    }

    /// Inspects `image` without opening any file it refers to, and accepts it only as a
    /// self-contained qcow2 or raw image: a recipe's image is someone else's file, and a qcow2
    /// backing file or external data file would make the conversion copy host files into the disk.
    static func info(of image: URL, tool: String) throws -> Info {
        try parseInfo(try output(tool, ["info", "--output=json", image.path]), image: image.lastPathComponent)
    }

    static func parseInfo(_ json: Data, image: String) throws -> Info {
        let info = try JSONDecoder().decode(Info.self, from: json)
        guard ["qcow2", "raw"].contains(info.format) else {
            throw VMError.unusableImage(image, "it is \(info.format), not qcow2 or raw")
        }
        if let backing = info.backingFilename {
            throw VMError.unusableImage(image, "it refers to a backing file, \(backing)")
        }
        if let dataFile = info.formatSpecific?.data?.dataFile {
            throw VMError.unusableImage(image, "it refers to an external data file, \(dataFile)")
        }
        return info
    }
}
