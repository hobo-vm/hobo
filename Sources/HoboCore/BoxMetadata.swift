import CryptoKit
import Foundation

/// `metadata.json` inside a `.box`. The hardware values are the box's defaults; a Boxcar may
/// override them per machine.
public struct BoxMetadata: Codable, Equatable, Sendable {
    public static let fileName = "metadata.json"
    public static let provider = "hobo"
    /// Matches `Package.swift`'s platform minimum.
    public static let minimumHost = "27.0"

    public var provider: String = BoxMetadata.provider
    public var name: String
    public var version: String
    public var description: String?
    public var guestOS: String = "macos"
    public var guestOSVersion: String
    public var arch: String = "arm64"
    public var minHost: String = BoxMetadata.minimumHost
    public var cpus: Int
    public var memory: String
    public var disk: String
    /// Hash of the box's disk and platform files, so identical builds are recognisable.
    public var contentSHA256: String
    public var recipeSHA256: String

    public init(
        name: String, version: String, description: String?, guestOSVersion: String,
        cpus: Int, memory: String, disk: String, contentSHA256: String, recipeSHA256: String
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.guestOSVersion = guestOSVersion
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.contentSHA256 = contentSHA256
        self.recipeSHA256 = recipeSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case provider, name, version, description, arch, cpus, memory, disk
        case guestOS = "guest_os"
        case guestOSVersion = "guest_os_version"
        case minHost = "min_host"
        case contentSHA256 = "content_sha256"
        case recipeSHA256 = "recipe_sha256"
    }

    public func encoded() throws -> Data { try JSONEncoder.sorted.encode(self) }

    /// One hash over several files, in the order given.
    public static func contentHash(of files: [URL]) throws -> String {
        var hasher = SHA256()
        for file in files {
            try hasher.update(contentsOf: file)
        }
        return hasher.finalize().hexString
    }
}

/// The post-install disk saved in the roundhouse, keyed by everything that shapes it.
public enum Checkpoint {
    public static func key(ipswSHA256: String, diskBytes: UInt64, conventions: String = Conventions.fingerprint) -> String {
        let input = "\(ipswSHA256)|\(diskBytes)|\(conventions)"
        return String(SHA256.hash(data: Data(input.utf8)).hexString.prefix(16))
    }
}
