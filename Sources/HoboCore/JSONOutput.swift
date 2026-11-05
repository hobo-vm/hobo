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
public struct VMSummary: Encodable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case stopped, running, suspended, crashed, building, failed, broken }

    public var name: String
    public var state: State
    public var bundle: String
    /// Bytes the VM's own files occupy on the host, without its snapshots. Blocks shared with a
    /// clone count in full.
    public var allocatedBytes: UInt64
    /// Bytes its snapshots hold that its own files don't. Only from `list`.
    public var snapshotBytes: UInt64?
    /// Its snapshots, oldest first. Only from `list`.
    public var snapshots: [Snapshot]?
    /// The VM process (`running`) or the build process (`building`).
    public var pid: Int32?
    /// The VM process's last exit status if `crashed`: negative for a signal.
    public var exitStatus: Int32?
    /// Bytes the saved state occupies, if `suspended`.
    public var savedStateBytes: UInt64?
    /// When it was suspended, if `suspended` and its `run.json` is readable.
    public var suspendedAt: Date?
    /// Absent while `building`, or when `failed` or `broken`.
    public var config: VMConfig?
    /// Whether the VM's window is showing (`hobo view`). Only for a `running` VM whose process
    /// answered; only the VM process knows, so only `VMLifecycle.listing()` fills it in.
    public var windowShown: Bool?
    /// What a `running` VM's process says it is doing, when that isn't plainly running: `starting`
    /// or `stopping` (a suspend is `stopping`, detail `saving state`). Only from `VMLifecycle.listing()`.
    public var phase: String?
    /// The VM process's detail for `phase`, e.g. `booting` or `shutting down over SSH`.
    public var phaseDetail: String?
    /// The idle timeout a `running` ephemeral VM's process says this run has; absent with `off`.
    /// Only from `VMLifecycle.listing()`.
    public var idleTimeoutSeconds: Int?
    /// What is left of it, rounded up. Absent while a request or window holds it or it isn't
    /// counting yet. Only from `VMLifecycle.listing()`.
    public var idleSecondsRemaining: Int?

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
        case .suspended(let config, let saved):
            state = .suspended
            self.config = config
            savedStateBytes = saved.bytes
            suspendedAt = saved.run?.suspendedAt
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

/// What `hobo list --json` reports. Blocks clones share count once in the totals but in full in each
/// VM's `allocatedBytes`, so `totalBytes` can be less than the VMs' sizes add up to.
public struct VMListing: Encodable, Equatable, Sendable {
    public var vms: [VMSummary]
    /// Bytes all the bundles occupy on the host, snapshots included.
    public var totalBytes: UInt64
    public var snapshotCount: Int
    /// The part of `totalBytes` held only by snapshots.
    public var totalSnapshotBytes: UInt64

    init(_ vms: [VMStore.VM], usage: DiskUsage) {
        self.vms = vms.map { vm in
            var summary = VMSummary(vm)
            summary.snapshots = usage.snapshots(of: vm)
            summary.snapshotBytes = usage.snapshotBytes[vm.name] ?? 0
            return summary
        }
        totalBytes = usage.totalBytes
        snapshotCount = self.vms.reduce(0) { $0 + ($1.snapshots?.count ?? 0) }
        totalSnapshotBytes = usage.totalSnapshotBytes
    }
}

/// What `hobo validate --json` reports about a recipe that parsed.
public struct RecipeSummary: Codable, Equatable, Sendable {
    public var path: String
    public var os: VMConfig.OS
    public var cpus: Int
    public var memory: UInt64
    public var disk: UInt64
    /// `latest`, or the pinned IPSW's or image's URL or path.
    public var source: String
    public var pinned: Bool
    public var provisionSteps: Int
    public var guiTesting: Bool
    public var sip: Bool
    public var amfi: Bool

    public init(_ recipe: Recipe, path: String) {
        self.path = path
        os = recipe.os
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
        guiTesting = recipe.guiTesting != nil
        sip = recipe.security.sip
        amfi = recipe.security.amfi
    }
}
