import Foundation

/// A snapshot of a VM (decision 13): the bundle's `snapshots/<tag>/`, holding APFS clones of the
/// platform files and `snapshot.json`. A live one, taken while the VM ran or was suspended, also
/// has a `suspended/` folder laid out as `SavedState` lays out a bundle's, which restoring clones
/// into the bundle so the ordinary resume takes over.
///
/// A snapshot is written to `snapshots/.saving-<tag>` and renamed into place, so `snapshots/<tag>`
/// exists only once complete. No tag starts with a dot, so listing skips what a crash left behind.
public struct Snapshot: Equatable, Sendable {
    public static let directoryName = "snapshots"
    public static let recordFile = "snapshot.json"
    private static let partialPrefix = ".saving-"

    public var tag: String
    public var record: SnapshotRecord
    /// Bytes of the memory and device state, or nil for a disk-only snapshot. The cloned platform
    /// files don't count: they share their blocks with the VM's until either changes them.
    public var savedStateBytes: UInt64?

    public init(tag: String, record: SnapshotRecord, savedStateBytes: UInt64?) {
        self.tag = tag
        self.record = record
        self.savedStateBytes = savedStateBytes
    }

    public var isLive: Bool { savedStateBytes != nil }

    public static func root(in bundle: URL) -> URL {
        bundle.appending(path: directoryName, directoryHint: .isDirectory)
    }

    public static func directory(_ tag: String, in bundle: URL) -> URL {
        root(in: bundle).appending(path: tag, directoryHint: .isDirectory)
    }

    /// A tag is a directory name, so it follows the rules for a VM's name.
    public static func validate(_ tag: String) throws {
        do {
            try VMStore.validate(tag)
        } catch {
            throw SnapshotError.invalidTag(tag)
        }
    }

    /// The bundle's snapshots, oldest first. A folder whose record doesn't decode isn't listed.
    public static func list(in bundle: URL) -> [Snapshot] {
        tags(in: bundle)
            .compactMap { load($0, in: bundle) }
            .sorted { ($0.record.createdAt, $0.tag) < ($1.record.createdAt, $1.tag) }
    }

    /// The snapshot `tag`, matched case-insensitively as VM names are.
    public static func find(_ tag: String, in bundle: URL) throws -> Snapshot {
        guard let existing = existingTag(matching: tag, in: bundle), let snapshot = load(existing, in: bundle) else {
            throw SnapshotError.notFound(vmName(of: bundle), tag)
        }
        return snapshot
    }

    /// Starts a snapshot: checks the tag is valid and free, clears what any earlier save left
    /// behind, and returns the folder to fill. Pair with `finish`.
    public static func begin(_ tag: String, in bundle: URL) throws -> URL {
        try validate(tag)
        if let existing = existingTag(matching: tag, in: bundle) { throw SnapshotError.exists(vmName(of: bundle), existing) }
        removePartials(in: bundle)
        let partial = root(in: bundle).appending(path: partialPrefix + tag, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        return partial
    }

    /// Records what `config` says the VM was as this snapshot was taken, and puts it in place.
    public static func finish(_ tag: String, partial: URL, in bundle: URL, config: VMConfig, createdAt: Date = .now) throws {
        try SnapshotRecord(config: config, createdAt: createdAt).write(to: partial.appending(path: recordFile))
        try FileManager.default.moveItem(at: partial, to: directory(tag, in: bundle))
    }

    /// Deletes a save that died partway. A save racing this one fails, and says so, rather than
    /// leaving anything half-written: only a complete folder is ever renamed into place.
    public static func removePartials(in bundle: URL) {
        let root = root(in: bundle)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries where entry.hasPrefix(partialPrefix) { try? FileManager.default.removeItem(at: root.appending(path: entry)) }
    }

    /// Deletes the snapshot `tag`, whether or not its record still decodes. It takes nothing from
    /// the VM, whatever state that is in: the VM's files and the snapshot's are separate clones.
    public static func delete(_ tag: String, in bundle: URL) throws {
        guard let existing = existingTag(matching: tag, in: bundle) else { throw SnapshotError.notFound(vmName(of: bundle), tag) }
        try FileManager.default.removeItem(at: directory(existing, in: bundle))
    }

    private static func tags(in bundle: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root(in: bundle).path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private static func existingTag(matching tag: String, in bundle: URL) -> String? {
        tags(in: bundle).first { $0.lowercased() == tag.lowercased() }
    }

    private static func load(_ tag: String, in bundle: URL) -> Snapshot? {
        let directory = directory(tag, in: bundle)
        guard let record = try? SnapshotRecord.load(from: directory.appending(path: recordFile)) else { return nil }
        return Snapshot(tag: tag, record: record, savedStateBytes: SavedState.load(in: directory)?.bytes)
    }

    private static func vmName(of bundle: URL) -> String { bundle.deletingPathExtension().lastPathComponent }
}

/// `snapshot.json`: what `config.json` said as the snapshot was taken, which restoring needs. The
/// disk's size goes back with the disk; CPUs and memory stay as they are now, and if they differ the
/// saved state can't be used.
public struct SnapshotRecord: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var cpus: Int
    public var memory: UInt64
    public var disk: UInt64
    public var diskGrowPending: Bool

    public init(config: VMConfig, createdAt: Date) {
        self.createdAt = createdAt
        cpus = config.cpus
        memory = config.memory
        disk = config.disk
        diskGrowPending = config.diskGrowPending
    }

    /// Whether saved state from this moment fits a VM now configured as `config`.
    public func savedStateFits(_ config: VMConfig) -> Bool {
        cpus == config.cpus && memory == config.memory
    }

    public static func load(from url: URL) throws -> SnapshotRecord {
        try VMConfig.decoder.decode(SnapshotRecord.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try VMConfig.encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// `{"tag": …, "kind": "live" | "disk", "createdAt": …, "cpus": n, "memory": n, "disk": n,
/// "savedStateBytes": n}`; the size is absent for a disk-only snapshot.
extension Snapshot: Encodable {
    private enum CodingKeys: String, CodingKey { case tag, kind, createdAt, cpus, memory, disk, savedStateBytes }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(isLive ? "live" : "disk", forKey: .kind)
        try container.encode(record.createdAt, forKey: .createdAt)
        try container.encode(record.cpus, forKey: .cpus)
        try container.encode(record.memory, forKey: .memory)
        try container.encode(record.disk, forKey: .disk)
        try container.encodeIfPresent(savedStateBytes, forKey: .savedStateBytes)
    }
}

public enum SnapshotError: Error, Equatable, CustomStringConvertible {
    case invalidTag(String)
    case exists(String, String)
    case notFound(String, String)
    case ephemeral(String)
    case notSnapshottable(String, String)
    case needsForce(String, tag: String, state: String)
    case stoppedWhileSaving(String, tag: String)
    case startedByOlderHobo(String)

    public var description: String {
        switch self {
        case .invalidTag(let tag):
            "invalid snapshot tag \"\(tag)\" (letters, digits, '.', '_' and '-', starting with a letter or digit, at most 63)"
        case .exists(let name, let tag): "\(name) already has a snapshot \"\(tag)\" (hobo snapshot delete \(name) \(tag) first)"
        case .notFound(let name, let tag): "\(name) has no snapshot \"\(tag)\" (hobo snapshot list \(name))"
        case .ephemeral(let name):
            "\(name) is ephemeral, and its snapshots would go with it (hobo set \(name) --keep keeps it, then snapshot it)"
        case .notSnapshottable(let name, let reason): "can't use snapshots of \(name): \(reason)"
        case .needsForce(let name, let tag, let state):
            "\(name) is \(state), and restoring would lose that (hobo snapshot restore --force \(name) \(tag))"
        case .stoppedWhileSaving(let name, let tag): "\(name) stopped before the snapshot finished, so \"\(tag)\" wasn't saved"
        case .startedByOlderHobo(let name):
            "\(name) was started by an older hobo that can't take snapshots; restart it with this one (hobo stop \(name), then hobo start \(name))"
        }
    }
}
