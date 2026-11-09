import Foundation
import HoboCore
import Virtualization

/// The files that make up one macOS VM: an ASIF disk plus the platform identity VZ needs to boot
/// it.
public struct MacVMBundle: VMBundle {
    public static let platformFiles = ["disk.asif", "aux.img", "hardware-model.bin", "machine-identifier.bin"]
    public static let hiDPIDisplay = true
    /// A macOS guest has no display mode smaller than 1024x640 points, so VZ's resizing stops there
    /// (seen on a macOS 27.2 guest: a 763x481 window left it at 1024x640, 2048x1280 pixels).
    public static let smallestFollowedWindow: CGSize? = CGSize(width: 1024, height: 640)

    /// Where a macOS guest mounts the automount-tagged shares.
    static let sharesMountPoint = "/Volumes/My Shared Files"

    public static let ntpClockCommand: String? = "sudo -n sntp -sS time.apple.com"

    /// `date` in its `mmddHHMMccyy.ss` form, in UTC: BSD `date` has no `-s`.
    public static func setClockCommand(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMddHHmmyyyy.ss"
        return "sudo -n date -u \(formatter.string(from: date)) >/dev/null"
    }

    /// A restored VM's virtio-fs device starts afresh on the host, and a macOS guest's handles into
    /// the shares go stale: lookups fail with ENOENT (checked 2026-11-02 on 27.2) until the mount
    /// is replaced. Files the guest had open in a share are lost either way.
    public static let remountSharesCommand: String? = {
        let mountPoint = shellQuote(sharesMountPoint)
        return "sudo -n umount -f \(mountPoint); sudo -n mkdir -p \(mountPoint) && "
            + "sudo -n mount -t virtiofs \(VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag) \(mountPoint)"
    }()

    /// Grows the boot volume's container (looked up, not assumed to be `disk0s2`) to fill its disk.
    public static let growDiskCommand =
        #"sudo -n diskutil apfs resizeContainer "$(diskutil info / | awk '/APFS Physical Store:/ { print $NF }')" 0"#

    public static func agentCommand(_ command: [String], gui: Bool) -> String {
        gui ? guiExecScript(command) : shellQuote(command)
    }

    /// Waits for auto-login, then enters the Aqua session. `launchctl asuser` needs root, and leaves
    /// the command root without the inner `sudo -u`, which in turn resets the environment, so the
    /// `PATH` is carried over to find what plain `exec` finds. TCC still attributes the command to
    /// the process that started it, hobo-agent, whose grants `[gui_testing]` wrote, and a kill of
    /// the process group reaches it.
    static func guiExecScript(_ command: [String]) -> String {
        """
        i=0
        until [ "$(stat -f %Su /dev/console)" = "$(id -un)" ] && launchctl print "gui/$(id -u)" >/dev/null 2>&1; do
          i=$((i + 1))
          if [ "$i" -ge \(GUISession.waitSeconds) ]; then
            echo "$(id -un)'s desktop session isn't up after \(GUISession.waitSeconds) seconds" >&2
            exit \(GUISession.unavailableStatus)
          fi
          sleep 1
        done
        exec sudo -n launchctl asuser "$(id -u)" sudo -n -u "$(id -un)" env "PATH=$PATH" \(shellQuote(command))
        """
    }

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

    /// The aux storage and hardware model stay: a clone with fresh aux storage never leaves
    /// firmware (decision 12).
    public func writeNewMachineIdentifier() throws {
        try VZMacMachineIdentifier().dataRepresentation.write(to: machineIdentifier, options: .atomic)
    }

    /// `shares` go on the macOS automount tag, so the guest mounts each at
    /// `/Volumes/My Shared Files/<name>` with nothing to run inside it.
    public func configuration(
        cpus: Int, memoryBytes: UInt64, macAddress: VZMACAddress, shares: [VMShare]
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
            widthInPixels: Int(GuestDisplay.pixels.width), heightInPixels: Int(GuestDisplay.pixels.height), pixelsPerInch: 80
        )]

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = cpus
        config.memorySize = memoryBytes
        config.graphicsDevices = [graphics]
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        )]
        config.networkDevices = [natNetwork(macAddress: macAddress)]
        config.socketDevices = [agentSocketDevice()]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if !shares.isEmpty {
            config.directorySharingDevices = [shareDevice(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag, shares: shares)]
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
    case replaceFailed(String, String)
    case commandFailed(String, Int32)
    case timedOut(String)
    case stoppedWithError
    case unexpectedAttachOutput(String)
    case needsGUISession
    case cancelled
    case securityMismatch(wanted: Recipe.Security, actual: Recipe.Security)
    case noDataVolume(String)
    case windowsUnsupportedHere
    case diskHasNoGPT(UInt64)
    case windowsInstallFailed(String)
    case missingQEMUImg
    case diskTooSmall(wanted: UInt64, image: UInt64)
    case spawnFailed(String, String)
    case unusableImage(String, String)
    case missingPayload(String)

    public var description: String {
        switch self {
        case .unsupportedHardwareModel: "the VM's hardware model is not supported on this host"
        case .invalidMachineIdentifier: "the VM's machine identifier is invalid"
        case .unsupportedRestoreImage: "this host cannot run the IPSW's macOS version"
        case .cloneFailed(let name, let reason): "cloning \(name) failed: \(reason)"
        case .replaceFailed(let name, let reason): "replacing \(name) failed: \(reason)"
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
        case .windowsUnsupportedHere: "Windows VMs need a private Virtualization framework setting this version of macOS doesn't have"
        case .windowsInstallFailed(let details): "installing Windows failed: \(details)"
        case .diskHasNoGPT(let lba): "the VM's disk has no partition table header at sector \(lba)"
        case .missingQEMUImg: "converting a Linux cloud image needs qemu-img: brew install qemu"
        case .spawnFailed(let executable, let reason): "couldn't run \(executable): \(reason)"
        case .diskTooSmall(let wanted, let image):
            "the recipe's disk (\(ByteSize(bytes: wanted))) is smaller than the image's (\(ByteSize(bytes: image)))"
        case .unusableImage(let image, let reason): "can't use the image \(image): \(reason)"
        case .missingPayload(let file): "this hobo build is missing \(file); reinstall it"
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

/// Runs a host tool to completion with no output, for tools that print progress counters
/// (`diskutil image`). Its last line of output goes in the error if it fails.
func runQuietly(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let last = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).last.map { ": \($0)" } ?? ""
        throw VMError.commandFailed(([executable] + arguments).joined(separator: " ") + last, process.terminationStatus)
    }
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
