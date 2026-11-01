import Foundation
import TOMLKit

/// The parsed contents of a project's `Boxcar` file.
public struct Boxcar: Equatable, Sendable {
    public static let fileName = "Boxcar"

    public var defaults: MachineSettings
    /// Machines in boot order. A Boxcar without `[[machine]]` tables yields a
    /// single machine named `default` built from its top-level keys.
    public var machines: [Machine]

    public init(defaults: MachineSettings = .init(), machines: [Machine]) {
        self.defaults = defaults
        self.machines = machines
    }

    public static func parse(_ toml: String) throws -> Boxcar {
        let raw = try TOMLDecoder().decode(RawBoxcar.self, from: toml)
        let defaults = raw.defaults ?? .init()
        let machines: [Machine]
        if let declared = raw.machine, !declared.isEmpty {
            machines = declared
        } else {
            machines = [Machine(name: "default", settings: raw.topLevel)]
        }
        var seen = Set<String>()
        for machine in machines where !seen.insert(machine.name).inserted {
            throw BoxcarError.duplicateMachine(machine.name)
        }
        return Boxcar(defaults: defaults, machines: machines)
    }

    public static func load(from directory: URL) throws -> Boxcar {
        let url = directory.appending(path: fileName)
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// The machine's settings with `[defaults]` filled in underneath.
    public func resolved(_ machine: Machine) -> MachineSettings {
        machine.settings.merged(over: defaults)
    }
}

public enum BoxcarError: Error, Equatable, CustomStringConvertible {
    case duplicateMachine(String)
    case invalidSize(String)

    public var description: String {
        switch self {
        case .duplicateMachine(let name): "Boxcar declares machine \"\(name)\" more than once"
        case .invalidSize(let value): "invalid size \"\(value)\" (expected e.g. \"512MB\" or \"8GB\")"
        }
    }
}

public struct Machine: Equatable, Sendable, Decodable {
    public var name: String
    public var settings: MachineSettings

    public init(name: String, settings: MachineSettings) {
        self.name = name
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case name }

    public init(from decoder: Decoder) throws {
        name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .name)
        settings = try MachineSettings(from: decoder)
    }
}

/// Settings shared by `[defaults]`, `[[machine]]` and a single-machine Boxcar's top level.
/// Every field is optional so that machine values can be layered over defaults.
public struct MachineSettings: Equatable, Sendable, Decodable {
    public var box: String?
    public var cpus: Int?
    public var memory: ByteSize?
    public var disk: ByteSize?
    public var gui: Bool?
    public var forwardedPorts: [ForwardedPort]?
    public var syncedFolders: [SyncedFolder]?
    public var provisioners: [Provisioner]?
    public var privateNetwork: PrivateNetwork?

    public init(
        box: String? = nil, cpus: Int? = nil, memory: ByteSize? = nil, disk: ByteSize? = nil,
        gui: Bool? = nil, forwardedPorts: [ForwardedPort]? = nil, syncedFolders: [SyncedFolder]? = nil,
        provisioners: [Provisioner]? = nil, privateNetwork: PrivateNetwork? = nil
    ) {
        self.box = box
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.gui = gui
        self.forwardedPorts = forwardedPorts
        self.syncedFolders = syncedFolders
        self.provisioners = provisioners
        self.privateNetwork = privateNetwork
    }

    private enum CodingKeys: String, CodingKey {
        case box, cpus, memory, disk, gui
        case forwardedPorts = "forwarded_port"
        case syncedFolders = "synced_folder"
        case provisioners = "provision"
        case privateNetwork = "private_network"
    }

    func merged(over base: MachineSettings) -> MachineSettings {
        MachineSettings(
            box: box ?? base.box,
            cpus: cpus ?? base.cpus,
            memory: memory ?? base.memory,
            disk: disk ?? base.disk,
            gui: gui ?? base.gui,
            forwardedPorts: forwardedPorts ?? base.forwardedPorts,
            syncedFolders: syncedFolders ?? base.syncedFolders,
            provisioners: provisioners ?? base.provisioners,
            privateNetwork: privateNetwork ?? base.privateNetwork
        )
    }
}

public struct ForwardedPort: Equatable, Sendable, Decodable {
    public var guest: Int
    public var host: Int
}

public struct SyncedFolder: Equatable, Sendable, Decodable {
    public enum Kind: String, Sendable, Decodable { case virtiofs, rsync }

    public var host: String
    public var guest: String
    public var type: Kind?
    public var readonly: Bool?
}

public struct Provisioner: Equatable, Sendable, Decodable {
    public enum Kind: String, Sendable, Decodable { case shell, file }
    public enum Run: String, Sendable, Decodable { case once, always, never }

    public var type: Kind
    public var inline: String?
    public var path: String?
    public var source: String?
    public var destination: String?
    public var privileged: Bool?
    public var run: Run?
    public var env: [String: String]?
}

public struct PrivateNetwork: Equatable, Sendable, Decodable {
    public var ip: String
}

/// A byte count written in the Boxcar as `"512MB"`, `"8GB"` etc. (binary units).
public struct ByteSize: Equatable, Sendable, Decodable {
    public var bytes: UInt64

    public init(bytes: UInt64) { self.bytes = bytes }

    /// Largest first, so `"8GB"` matches `GB` rather than `B`.
    private static let units: [(suffix: String, multiplier: UInt64)] = [
        ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10), ("B", 1),
    ]

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let (suffix, multiplier) = Self.units.first(where: { trimmed.hasSuffix($0.suffix) }),
              let value = UInt64(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)),
              case (let product, false) = value.multipliedReportingOverflow(by: multiplier)
        else { throw BoxcarError.invalidSize(text) }
        bytes = product
    }

    public init(from decoder: Decoder) throws {
        try self.init(parsing: decoder.singleValueContainer().decode(String.self))
    }
}

extension ByteSize: CustomStringConvertible {
    /// The largest unit that divides evenly, e.g. `"8GB"`; `"0B"` for zero.
    public var description: String {
        let (suffix, multiplier) = Self.units.first { bytes >= $0.multiplier && bytes % $0.multiplier == 0 } ?? ("B", 1)
        return "\(bytes / multiplier)\(suffix)"
    }
}

private struct RawBoxcar: Decodable {
    var defaults: MachineSettings?
    var machine: [Machine]?
    var topLevel: MachineSettings

    private enum CodingKeys: String, CodingKey { case defaults, machine }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaults = try container.decodeIfPresent(MachineSettings.self, forKey: .defaults)
        machine = try container.decodeIfPresent([Machine].self, forKey: .machine)
        topLevel = try MachineSettings(from: decoder)
    }
}
