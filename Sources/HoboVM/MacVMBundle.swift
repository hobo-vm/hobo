import Foundation
import HoboCore
import Virtualization

/// The files that make up one macOS VM: an ASIF disk plus the platform identity VZ needs to boot
/// it.
public struct MacVMBundle: Sendable {
    public static let platformFiles = ["disk.asif", "aux.img", "hardware-model.bin", "machine-identifier.bin"]

    /// The guest display's configured size. A window resizes it while showing (`VMWindow`),
    /// and hiding the window puts it back, so headless runs always see this.
    static let displayPixels = CGSize(width: 1920, height: 1200)

    /// Where a macOS guest mounts the automount-tagged shares.
    static let sharesMountPoint = "/Volumes/My Shared Files"

    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public var disk: URL { directory.appending(path: "disk.asif") }
    public var auxiliaryStorage: URL { directory.appending(path: "aux.img") }
    public var hardwareModel: URL { directory.appending(path: "hardware-model.bin") }
    public var machineIdentifier: URL { directory.appending(path: "machine-identifier.bin") }

    /// Creates an empty bundle ready for `VZMacOSInstaller`.
    public static func create(at directory: URL, hardwareModel: VZMacHardwareModel, diskBytes: UInt64) throws -> MacVMBundle {
        let bundle = MacVMBundle(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run("/usr/sbin/diskutil", [
            "image", "create", "blank", "--format", "ASIF", "--fs", "None",
            "--size", String(diskBytes), bundle.disk.path,
        ])
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorage, hardwareModel: hardwareModel, options: [])
        try hardwareModel.dataRepresentation.write(to: bundle.hardwareModel)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        return bundle
    }

    /// Copies the bundle's files to `destination` as APFS clones, so it is instant and free.
    public func clone(to destination: URL) throws -> MacVMBundle {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in Self.platformFiles {
            let target = destination.appending(path: name)
            try? FileManager.default.removeItem(at: target)
            guard copyfile(directory.appending(path: name).path, target.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 else {
                throw VMError.cloneFailed(name, String(cString: strerror(errno)))
            }
        }
        return MacVMBundle(directory: destination)
    }

    /// Bytes the disk image actually occupies on the host.
    public func allocatedDiskBytes() -> UInt64 {
        let values = try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? 0)
    }

    /// `shares` go on the macOS automount tag, so the guest mounts each at
    /// `/Volumes/My Shared Files/<name>` with nothing to run inside it.
    public func configuration(
        cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress, shares: [VMShare] = []
    ) throws -> VZVirtualMachineConfiguration {
        guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: hardwareModel)), model.isSupported else {
            throw VMError.unsupportedHardwareModel
        }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIdentifier)) else {
            throw VMError.invalidMachineIdentifier
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorage)

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: Int(Self.displayPixels.width), heightInPixels: Int(Self.displayPixels.height), pixelsPerInch: 80
        )]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = macAddress

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = cpus
        config.memorySize = memoryBytes
        config.graphicsDevices = [graphics]
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        )]
        config.networkDevices = [network]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if !shares.isEmpty {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            device.share = VZMultipleDirectoryShare(directories: Dictionary(uniqueKeysWithValues: shares.map { share in
                (share.name, VZSharedDirectory(url: URL(filePath: share.path, directoryHint: .isDirectory), readOnly: share.readOnly))
            }))
            config.directorySharingDevices = [device]
        }
        try config.validate()
        return config
    }
}

public enum VMError: Error, CustomStringConvertible {
    case unsupportedHardwareModel
    case invalidMachineIdentifier
    case unsupportedRestoreImage
    case cloneFailed(String, String)
    case commandFailed(String, Int32)
    case timedOut(String)
    case stoppedWithError
    case unexpectedAttachOutput(String)
    case needsGUISession
    case cancelled
    case securityMismatch(wanted: Recipe.Security, actual: Recipe.Security)
    case noDataVolume(String)

    public var description: String {
        switch self {
        case .unsupportedHardwareModel: "the VM's hardware model is not supported on this host"
        case .invalidMachineIdentifier: "the VM's machine identifier is invalid"
        case .unsupportedRestoreImage: "this host cannot run the IPSW's macOS version"
        case .cloneFailed(let name, let reason): "cloning \(name) failed: \(reason)"
        case .commandFailed(let command, let status): "\(command) exited with status \(status)"
        case .timedOut(let what): "timed out \(what)"
        case .stoppedWithError: "the VM stopped with an error"
        case .unexpectedAttachOutput(let disk): "could not read diskutil's output for attaching \(disk)"
        case .needsGUISession:
            "this recipe turns SIP off, which needs you at this Mac's screen partway through: run hobo create from a GUI login session"
        case .cancelled: "build cancelled"
        case .securityMismatch(let wanted, let actual):
            "the guest runs with SIP \(actual.sip ? "on" : "off") and AMFI \(actual.amfi ? "on" : "off"); the recipe asks for SIP \(wanted.sip ? "on" : "off") and AMFI \(wanted.amfi ? "on" : "off")"
        case .noDataVolume(let disk): "\(disk) has no single APFS Data volume"
        }
    }
}

/// Runs a host tool to completion, inheriting stdout/stderr.
func run(_ executable: String, _ arguments: [String]) throws {
    _ = try runProcess(executable, arguments, capture: false)
}

/// Runs a host tool to completion and returns its stdout; stderr is inherited.
func output(_ executable: String, _ arguments: [String]) throws -> Data {
    try runProcess(executable, arguments, capture: true)
}

private func runProcess(_ executable: String, _ arguments: [String], capture: Bool) throws -> Data {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    if capture { process.standardOutput = pipe }
    try process.run()
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw VMError.commandFailed(([executable] + arguments).joined(separator: " "), process.terminationStatus)
    }
    return data
}
