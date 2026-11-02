import Foundation

/// A VM's runtime configuration, the bundle's `config.json`. `create` copies the recipe's defaults
/// here; from then on this, not the recipe, is the truth (`hobo set` changes it).
public struct VMConfig: Codable, Equatable, Sendable {
    public enum Engine: String, Codable, Sendable { case vz, qemu }
    public enum OS: String, Codable, Sendable { case macOS, linux, windows }

    public var engine: Engine
    public var os: OS
    public var cpus: Int
    public var memory: UInt64
    public var disk: UInt64
    /// Fixed for the VM's life, so its DHCP lease (and `hobo ip`) is stable; a clone gets a new one.
    public var macAddress: String
    /// e.g. `27.2.0 (26B123)`.
    public var guestOSVersion: String
    public var created: Date
    /// SHA-256 of the recipe file as built (copied verbatim to the bundle's `recipe.toml`).
    public var recipeSHA256: String
    /// SHA-256 of the install image.
    public var sourceSHA256: String
    /// System Integrity Protection, as checked in the guest at the end of create (`[security]`).
    @MissingAsTrue public var sip: Bool
    /// AppleMobileFileIntegrity, as checked in the guest at the end of create (`[security]`).
    @MissingAsTrue public var amfi: Bool

    public init(
        engine: Engine, os: OS, cpus: Int, memory: UInt64, disk: UInt64, macAddress: String,
        guestOSVersion: String, created: Date, recipeSHA256: String, sourceSHA256: String,
        sip: Bool = true, amfi: Bool = true
    ) {
        self.engine = engine
        self.os = os
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.macAddress = macAddress
        self.guestOSVersion = guestOSVersion
        self.created = created
        self.recipeSHA256 = recipeSHA256
        self.sourceSHA256 = sourceSHA256
        self.sip = sip
        self.amfi = amfi
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder.sorted
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func load(from url: URL) throws -> VMConfig {
        try decoder.decode(VMConfig.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }
}
