import Foundation
import HoboCore
import Synchronization

/// The disk image that installs Windows with nobody there, attached as USB storage, built fresh by
/// each create (`install.cmd` says what it does when it boots). Two partitions, since the firmware
/// only reads FAT but `install.wim` doesn't fit on it:
/// - FAT32: what booting needs, with `loader.c` in front of Windows Boot Manager.
/// - exFAT: the whole ISO, which Windows Setup looks for even though it installs nothing itself
///   here, then the answer file, drivers and guest files, and the script's result afterwards.
public enum WindowsInstallMedia {
    /// Where a create's copies of the files Hobo puts in every Windows guest are.
    struct PackageFiles: Sendable {
        var virtioWin: URL
        var openSSH: URL
        var winFsp: URL
        /// `vzDisplayDriver`, for `[windows] resizable_display`; nil keeps virtio-win's viogpudo.
        var vzDisplayDriver: URL?
    }

    /// A download of one of those files.
    struct PinnedPackage: Sendable {
        var url: URL
        var sha256: String
    }

    static let virtioWin = PinnedPackage(
        url: URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!,
        sha256: "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"
    )
    static let openSSH = PinnedPackage(
        url: URL(string: "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-ARM64-v10.4.0.0.msi")!,
        sha256: "75fa139d8975eedb706d9180f454e2148af09d417692825f383fe00610b00e21"
    )
    /// viogpudo with the fix that lets it change mode under VZ, test-signed: built from the
    /// `vz-scanout` branch of a fork of virtio-win's source, until a signed release has the fix
    /// (design.md decision 20). A zip of a `viogpudo` folder holding the .inf, .sys and .cat.
    static let vzDisplayDriver = PinnedPackage(
        url: URL(string: "https://github.com/ggal625/kvm-guest-drivers-windows/releases/download/viogpudo-vz-1/viogpudo-vz-arm64.zip")!,
        sha256: "a3822c5a24f51d226f3b850d1e9613e128c6c4b531b42f6805d27da22d4f0256"
    )
    static let winFsp = PinnedPackage(
        url: URL(string: "https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi")!,
        sha256: "073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a"
    )

    /// Microsoft's licence and download page leave fetching the ISO to the user.
    public static let bringYourOwnISO = """
        Hobo doesn't download Windows. Get the ISO from \
        https://www.microsoft.com/en-us/software-download/windows11arm64, then run \
        `hobo init --os windows <path-to-iso>`.
        """

    /// What each guest needs from virtio-win: the display, network, entropy, memory balloon and shares.
    private static let drivers = ["viogpudo", "NetKVM", "viorng", "Balloon", "viofs"]
    /// Where install.cmd finds `vzDisplayDriver`.
    private static let testSignedDrivers = "hobo/test-signed-drivers"
    private static let resultFile = "hobo/result"
    private static let logFile = "hobo/install.log"
    private static let bootVolume = "HOBOBOOT"
    private static let dataVolume = "HOBOINST"
    /// Beyond the ISO: the boot partition, the drivers and the packages.
    private static let mediaHeadroom: UInt64 = 2 << 30
    /// Beyond `boot.wim`: the boot manager and its files, the loader and the driver.
    private static let bootPartitionHeadroom: UInt64 = 512 << 20
    /// The disks this process has attached and not yet ejected, for `ejectAttached`.
    private static let attachedDisks = Mutex<Set<String>>([])

    /// Throws unless `iso` is a Windows on Arm installer.
    public static func validate(_ iso: URL) throws {
        try withInstaller(iso) { _ in }
    }

    private static func withInstaller(_ iso: URL, _ body: (URL) throws -> Void) throws {
        try withAttached(iso) { volumes in
            guard let root = volumes.first, isInstaller(root: root) else {
                throw VMError.unusableImage(iso.lastPathComponent, "it isn't a Windows on Arm installer")
            }
            try body(root)
        }
    }

    static func isInstaller(root: URL) -> Bool {
        let exists = { (path: String) in FileManager.default.fileExists(atPath: root.appending(path: path).path) }
        return (exists("sources/install.wim") || exists("sources/install.esd")) && exists("efi/boot/bootaa64.efi")
    }

    /// Writes the media to `image`.
    static func create(at image: URL, iso: URL, packages: PackageFiles, computerName: String, timeZone: String) throws {
        let isoBytes = try fileSize(iso)
        // A whole number of MiB, since VZ won't attach a raw image of a size that isn't sectors.
        try makeSparseFile(image, bytes: roundedToMiB(isoBytes + mediaHeadroom))
        let disk = try attachUnmounted(image)
        defer { eject(disk) }

        try withInstaller(iso) { root in
            let bootBytes = roundedToMiB(try fileSize(root.appending(path: "sources/boot.wim")) + bootPartitionHeadroom)
            try runQuietly("/usr/sbin/diskutil", [
                "partitionDisk", "-noEFI", disk, "GPT", "MS-DOS FAT32", bootVolume, "\(bootBytes)B", "ExFAT", dataVolume, "R",
            ])
            // Partitioning mounts them where Finder shows them, under names another create may hold.
            try runQuietly("/usr/sbin/diskutil", ["unmountDisk", disk])
            try withMounted(["\(disk)s1", "\(disk)s2"]) { mounted in
                let answerFile = answerFile(computerName: computerName, timeZone: timeZone)
                try writeBootPartition(mounted[0], from: root, answerFile: answerFile)
                try writeDataPartition(mounted[1], from: root, packages: packages, answerFile: answerFile)
            }
        }
    }

    /// Reads what `install.cmd` reported, once the VM has stopped. Throws with the end of its log
    /// unless it says it finished.
    static func checkResult(of image: URL) throws {
        try withAttached(image) { volumes in
            guard let volume = volumes.first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "hobo").path) }) else {
                throw VMError.windowsInstallFailed("its media has no results")
            }
            let result = (try? String(contentsOf: volume.appending(path: resultFile), encoding: .utf8)) ?? ""
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" { return }
            // Windows writes the log in its own code page; Latin-1 reads any bytes.
            let log = (try? String(contentsOf: volume.appending(path: logFile), encoding: .isoLatin1)) ?? "no log was written"
            throw VMError.windowsInstallFailed(log.split(whereSeparator: \.isNewline).suffix(40).joined(separator: "\n"))
        }
    }

    /// The answer file goes on both partitions: without it here, Setup waits at its logo forever.
    private static func writeBootPartition(_ volume: URL, from iso: URL, answerFile: String) throws {
        let manager = FileManager.default
        for directory in ["EFI/BOOT", "EFI/hobo", "sources"] {
            try manager.createDirectory(at: volume.appending(path: directory), withIntermediateDirectories: true)
        }
        try Data(answerFile.utf8).write(to: volume.appending(path: "autounattend.xml"))
        for file in try manager.contentsOfDirectory(at: iso, includingPropertiesForKeys: nil) where file.pathExtension == "efi" {
            try copy(file, to: volume.appending(path: file.lastPathComponent))
        }
        try copy(iso.appending(path: "boot"), to: volume.appending(path: "boot"))
        try copy(iso.appending(path: "efi/microsoft"), to: volume.appending(path: "EFI/microsoft"))
        try copy(iso.appending(path: "efi/boot/bootaa64.efi"), to: volume.appending(path: "EFI/BOOT/windows.efi"))
        try copy(iso.appending(path: "sources/boot.wim"), to: volume.appending(path: "sources/boot.wim"))
        try WindowsBootFiles.loader.write(to: volume.appending(path: "EFI/BOOT/BOOTAA64.EFI"))
        try WindowsBootFiles.framebuffer.write(to: volume.appending(path: "EFI/hobo/framebuffer.efi"))
    }

    private static func writeDataPartition(
        _ volume: URL, from iso: URL, packages: PackageFiles, answerFile: String
    ) throws {
        let manager = FileManager.default
        try copy(iso, to: volume)
        // ditto can report success having run out of room.
        guard isInstaller(root: volume) else { throw VMError.unusableImage(iso.lastPathComponent, "it didn't all fit on the install media") }
        let hobo = volume.appending(path: "hobo")
        let guest = hobo.appending(path: "guest")
        try manager.createDirectory(at: guest, withIntermediateDirectories: true)

        try Data(answerFile.utf8).write(to: volume.appending(path: "autounattend.xml"))
        try writeScript(PackageResources.install_cmd, to: hobo.appending(path: "install.cmd"))
        try writeScript(PackageResources.SetupComplete_cmd, to: hobo.appending(path: "SetupComplete.cmd"))
        try WindowsBootFiles.framebuffer.write(to: hobo.appending(path: "framebuffer.efi"))
        for (script, name) in [
            (PackageResources.setup_ps1, "setup.ps1"), (PackageResources.finish_setup_ps1, "finish-setup.ps1"),
            (PackageResources.network_watchdog_ps1, "network-watchdog.ps1"),
            (PackageResources.common_ps1, "common.ps1"), (PackageResources.exec_ps1, "exec.ps1"),
            (PackageResources.gui_exec_ps1, "gui-exec.ps1"), (PackageResources.gui_run_ps1, "gui-run.ps1"),
            (PackageResources.cancel_ps1, "cancel.ps1"), (PackageResources.screenshot_ps1, "screenshot.ps1"),
            (PackageResources.display_follower_ps1, "display-follower.ps1"),
        ] {
            try writeScript(script, to: guest.appending(path: name))
        }
        try Data(Conventions.insecurePublicKeys.joined(separator: "\r\n").utf8).write(to: guest.appending(path: "authorized_keys"))
        try copy(packages.openSSH, to: guest.appending(path: packages.openSSH.lastPathComponent))
        try copy(packages.winFsp, to: guest.appending(path: packages.winFsp.lastPathComponent))

        try withAttached(packages.virtioWin) { volumes in
            guard let root = volumes.first else { throw VMError.unusableImage(packages.virtioWin.lastPathComponent, "it has no volume") }
            for driver in drivers where !(driver == "viogpudo" && packages.vzDisplayDriver != nil) {
                let target = hobo.appending(path: "drivers/\(driver)")
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                let source = root.appending(path: "\(driver)/w11/ARM64")
                // Without its debug symbols, which are most of the bytes.
                for file in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                where file.pathExtension.lowercased() != "pdb" {
                    try copy(file, to: target.appending(path: file.lastPathComponent))
                }
            }
            try copy(root.appending(path: "viofs/w11/ARM64/virtiofs.exe"), to: guest.appending(path: "virtiofs.exe"))
        }
        // Its own folder, which install.cmd adds with /ForceUnsigned and takes as the sign to turn
        // test signing on.
        if let zip = packages.vzDisplayDriver {
            try runQuietly("/usr/bin/ditto", ["-x", "-k", "--norsrc", "--noextattr", "--noacl", zip.path, volume.appending(path: testSignedDrivers).path])
        }
    }

    /// The answer file with this VM's values in. They're already safe in XML: `computerName` is
    /// letters, digits and hyphens, and a time zone comes from `hostTimeZone`.
    static func answerFile(computerName: String, timeZone: String) -> String {
        String(decoding: PackageResources.autounattend_xml, as: UTF8.self)
            .replacingOccurrences(of: "@@NAME@@", with: computerName)
            .replacingOccurrences(of: "@@TIMEZONE@@", with: timeZone)
    }

    /// `cmd.exe` needs CRLF line ends, and they're harmless to PowerShell.
    private static func writeScript(_ bytes: [UInt8], to file: URL) throws {
        try Data(crlf(String(decoding: bytes, as: UTF8.self)).utf8).write(to: file)
    }

    static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// The Windows name of this Mac's time zone, so that the guest's clock reads the same.
    static func hostTimeZone(identifier: String = TimeZone.current.identifier) -> String {
        var name = [UInt16](repeating: 0, count: 128)
        let id = Array(identifier.utf16)
        var status: Int32 = 0
        let length = ucal_getWindowsTimeZoneID(id, Int32(id.count), &name, Int32(name.count), &status)
        // ICU knows every zone macOS offers; UTC is a fine clock for one it doesn't. Its warnings are
        // negative and its errors positive.
        guard status <= 0, length > 0 else { return "UTC" }
        return String(decoding: name.prefix(Int(length)), as: UTF16.self)
    }

    private static func roundedToMiB(_ bytes: UInt64) -> UInt64 {
        (bytes + (1 << 20) - 1) / (1 << 20) * (1 << 20)
    }

    private static func fileSize(_ file: URL) throws -> UInt64 {
        // Resolved first, since the ISO may well be a symbolic link.
        UInt64(try file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private static func makeSparseFile(_ file: URL, bytes: UInt64) throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    /// `ditto`, since it leaves out the `._` files macOS would otherwise add on FAT and exFAT, which DISM
    /// chokes on next to the drivers. The ISO's files are read-only, which neither volume keeps.
    private static func copy(_ source: URL, to target: URL) throws {
        try runQuietly("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", source.path, target.path])
    }

    private static func attachUnmounted(_ image: URL) throws -> String {
        let attached = try output("/usr/sbin/diskutil", ["image", "attach", "--noMount", image.path])
        guard let disk = String(decoding: attached, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw VMError.unexpectedAttachOutput(image.path)
        }
        attachedDisks.withLock { _ = $0.insert(disk) }
        return disk
    }

    private static func eject(_ disk: String) {
        try? runQuietly("/usr/sbin/diskutil", ["eject", disk])
        attachedDisks.withLock { _ = $0.remove(disk) }
    }

    /// For an interrupted create, which exits with no chance to unwind: an image left attached holds
    /// on to its deleted blocks, and an ISO its mount, until the next restart. Forced, since what
    /// was copying from them may still be running.
    static func ejectAttached() {
        for disk in attachedDisks.withLock({ $0 }) {
            try? runQuietly("/usr/sbin/diskutil", ["unmountDisk", "force", disk])
            eject(disk)
        }
    }

    /// Mounts `partitions` in temporary directories for the length of `body`.
    private static func withMounted(_ partitions: [String], _ body: ([URL]) throws -> Void) throws {
        var mounted: [(partition: String, directory: URL)] = []
        defer {
            for (partition, directory) in mounted {
                try? runQuietly("/usr/sbin/diskutil", ["unmount", partition])
                // Not removeItem, which would empty the volume if it's still mounted there.
                rmdir(directory.path)
            }
        }
        for partition in partitions {
            let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-media-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try runQuietly("/usr/sbin/diskutil", ["mount", "-mountPoint", directory.path, partition])
            mounted.append((partition, directory))
        }
        try body(mounted.map(\.directory))
    }

    /// Holds a lock named after `image` for the length of `body`. Attaching an image that's already
    /// attached gets the same disk, which ejecting then takes from whoever else is using it: `hobo init`
    /// or another create, say, while a create copies the same ISO. So its users take turns, across
    /// processes. Without the lock file, they carry on as if there were no one else.
    private static func takingTurns(with image: URL, _ body: () throws -> Void) throws {
        let key = VMStore.sha256(Data(image.resolvingSymlinksInPath().path.utf8)).prefix(16)
        let lock = FileManager.default.temporaryDirectory.appending(path: "hobo-image-\(key).lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { if descriptor >= 0 { close(descriptor) } }
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        try body()
    }

    /// Mounts an ISO or the media read-only, out of Finder's sight, for the length of `body`.
    static func withAttached(_ image: URL, _ body: ([URL]) throws -> Void) throws {
        try takingTurns(with: image) { try attachAndMount(image, body) }
    }

    private static func attachAndMount(_ image: URL, _ body: ([URL]) throws -> Void) throws {
        let attached = String(decoding: try output("/usr/sbin/diskutil", [
            "image", "attach", "--readOnly", "--nobrowse", image.path,
        ]), as: UTF8.self)
        let lines = attached.split(whereSeparator: \.isNewline)
        guard let disk = lines.first?.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw VMError.unexpectedAttachOutput(image.path)
        }
        attachedDisks.withLock { _ = $0.insert(disk) }
        defer { eject(disk) }
        try body(lines.compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let last = fields.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("/") else { return nil }
            return URL(filePath: last, directoryHint: .isDirectory)
        })
    }
}

@_silgen_name("ucal_getWindowsTimeZoneID")
private func ucal_getWindowsTimeZoneID(
    _ id: UnsafePointer<UInt16>, _ length: Int32, _ winid: UnsafeMutablePointer<UInt16>, _ capacity: Int32,
    _ status: UnsafeMutablePointer<Int32>
) -> Int32
