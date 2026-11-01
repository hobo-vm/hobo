import Foundation

/// The JSON that `--json` prints (and that `hobo mcp` will return): ISO 8601 dates, sizes in bytes,
/// sorted keys so the output diffs cleanly.
public enum HoboJSON {
    /// A whole document, pretty-printed, for a command that prints one result.
    public static func document(_ value: some Encodable) throws -> Data {
        try encoder(pretty: true).encode(value)
    }

    /// One line, no newline, for a command that streams events (JSON Lines).
    public static func line(_ value: some Encodable) throws -> Data {
        try encoder(pretty: false).encode(value)
    }

    private static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// A VM as `--json` reports it: by `list`, and as the result of `create` and `rename`.
public struct VMSummary: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case stopped, running, crashed, building, failed, broken }

    public var name: String
    public var state: State
    public var bundle: String
    /// Bytes the bundle occupies on the host.
    public var allocatedBytes: UInt64
    /// The VM process (`running`) or the build process (`building`).
    public var pid: Int32?
    /// The VM process's last exit status if `crashed`: negative for a signal.
    public var exitStatus: Int32?
    /// Absent while `building`, or when `failed` or `broken`.
    public var config: VMConfig?
    /// Whether the VM's window is showing (`hobo view`). Only for a `running` VM whose process
    /// answered; filled in by the client, since only the VM process knows.
    public var windowShown: Bool?

    public init(_ vm: VMStore.VM) {
        name = vm.name
        bundle = vm.bundle.path
        allocatedBytes = vm.allocatedBytes
        switch vm.status {
        case .stopped(let config):
            state = .stopped
            self.config = config
        case .running(let config, let pid):
            state = .running
            self.config = config
            self.pid = pid
        case .crashed(let config, let exitStatus):
            state = .crashed
            self.config = config
            self.exitStatus = exitStatus
        case .building(let pid):
            state = .building
            self.pid = pid
        case .failed: state = .failed
        case .broken: state = .broken
        }
    }
}

/// What `hobo validate --json` reports about a recipe that parsed.
public struct RecipeSummary: Codable, Equatable, Sendable {
    public var path: String
    public var cpus: Int
    public var memory: UInt64
    public var disk: UInt64
    /// `latest`, or the pinned IPSW's URL or path.
    public var source: String
    public var pinned: Bool
    public var provisionSteps: Int

    public init(_ recipe: Recipe, path: String) {
        self.path = path
        cpus = recipe.cpus
        memory = recipe.memory.bytes
        disk = recipe.disk.bytes
        switch recipe.source {
        case .latest: source = "latest"
        case .remote(let url, _): source = url.absoluteString
        case .local(let url, _): source = url.path
        }
        pinned = recipe.source.isPinned
        provisionSteps = recipe.provisioners.count
    }
}
