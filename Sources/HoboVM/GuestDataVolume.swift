import Foundation

/// The guest's Data volume, mounted on the host while the VM is stopped. It is not encrypted
/// (no FileVault), and mounting it as a regular user ignores ownership, so its files are writable
/// without root; the host's SIP doesn't cover a foreign volume.
enum GuestDataVolume {
    /// Attaches `disk`, mounts its Data volume (hidden from Finder and Spotlight) for `body`, then
    /// unmounts and ejects it. The VM must be stopped.
    static func withMounted<T>(_ disk: URL, _ body: (URL) throws -> T) throws -> T {
        let attached = try output("/usr/sbin/diskutil", ["image", "attach", "--noMount", "--plist", disk.path])
        guard let plist = try PropertyListSerialization.propertyList(from: attached, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let whole = entities.first?["dev-entry"] as? String
        else { throw VMError.unexpectedAttachOutput(disk.lastPathComponent) }
        defer { try? run("/usr/sbin/diskutil", ["eject", whole]) }

        let data = entities.filter { $0["role"] as? String == "Data" }.compactMap { $0["dev-entry"] as? String }
        guard data.count == 1 else { throw VMError.noDataVolume(disk.lastPathComponent) }
        let mountPoint = FileManager.default.temporaryDirectory.appending(path: "hobo-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        try run("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", mountPoint.path, data[0]])
        defer { try? run("/usr/sbin/diskutil", ["unmount", mountPoint.path]) }
        return try body(mountPoint)
    }
}
