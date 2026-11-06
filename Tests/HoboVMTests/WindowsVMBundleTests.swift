import Foundation
@testable import HoboCore
import Testing
@testable import HoboVM

/// A resize against a real (tiny) ASIF image, which needs no entitlement, so it runs without
/// HOBO_INTEGRATION. Windows powers off at boot if this goes wrong, so it's otherwise only seen
/// by the hour-long integration test.
@Suite struct WindowsVMBundleTests {
    private static let megabyte: UInt64 = 1 << 20

    private func withBundle(partitioned: Bool, _ body: (WindowsVMBundle) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-bundle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = WindowsVMBundle(directory: directory)
        try runQuietly("/usr/sbin/diskutil", [
            "image", "create", "blank", "--format", "ASIF", "--fs", "None", "--size", String(64 * Self.megabyte), bundle.disk.path,
        ])
        if partitioned {
            try attached(bundle) { device in
                try runQuietly("/usr/sbin/diskutil", ["partitionDisk", device, "1", "GPT", "Free Space", "x", "100%"])
            }
        }
        try body(bundle)
    }

    private func attached(_ bundle: WindowsVMBundle, _ body: (String) throws -> Void) throws {
        let attached = try output("/usr/sbin/diskutil", ["image", "attach", "--noMount", bundle.disk.path])
        let device = try #require(String(decoding: attached, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init))
        defer { try? runQuietly("/usr/sbin/diskutil", ["eject", device]) }
        try body(device)
    }

    /// With the disk open for reading, which partitioning wouldn't stand for.
    private func reading(_ bundle: WindowsVMBundle, _ body: (FileHandle) throws -> Void) throws {
        try attached(bundle) { device in
            let handle = try FileHandle(forReadingFrom: URL(filePath: device))
            defer { try? handle.close() }
            try body(handle)
        }
    }

    private func header(of device: FileHandle, lba: UInt64) throws -> GPTHeader {
        try device.seek(toOffset: lba * 512)
        return try #require(GPTHeader(sector: try device.read(upToCount: 512) ?? Data()))
    }

    private func checksumHolds(_ header: GPTHeader) -> Bool {
        var bytes = header.sector.prefix(92)
        let stored = bytes[16..<20].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        bytes.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        return GPTHeader.crc32(Data(bytes)) == stored
    }

    @Test func aResizeKeepsTheGUIDInBothHeaders() throws {
        try withBundle(partitioned: true) { bundle in
            var original = Data()
            var originalBackup: UInt64 = 0
            try reading(bundle) { device in
                let primary = try header(of: device, lba: 1)
                original = primary.diskGUID
                originalBackup = primary.alternateLBA
            }
            try bundle.keepingDiskIdentity {
                try runQuietly("/usr/sbin/diskutil", [
                    "image", "resize", "--image-only", "--size", String(128 * Self.megabyte), bundle.disk.path,
                ])
            }
            try reading(bundle) { device in
                let primary = try header(of: device, lba: 1)
                #expect(primary.alternateLBA > originalBackup, "the backup header moved to the new end")
                let backup = try header(of: device, lba: primary.alternateLBA)
                #expect(primary.diskGUID == original)
                #expect(backup.diskGUID == original)
                #expect(checksumHolds(primary))
                #expect(checksumHolds(backup))
            }
        }
    }

    /// Resizing it anyway would lose the identity for good, with nothing to put back.
    @Test func aDiskWithNoGPTIsAnErrorBeforeAnyResize() throws {
        try withBundle(partitioned: false) { bundle in
            var resized = false
            #expect {
                try bundle.keepingDiskIdentity { resized = true }
            } throws: { error in
                (error as? VMError)?.description == VMError.diskHasNoGPT(1).description
            }
            #expect(!resized)
        }
    }
}
