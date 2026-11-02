import Foundation

/// A `hobo set` change to a stopped VM's `config.json`: each setting to change, nil for those left
/// alone. The disk only grows (decision 9): its ASIF image already returns freed blocks to the
/// host, so a smaller size would save nothing.
public struct VMSettings: Equatable, Sendable {
    public var cpus: Int?
    public var memory: ByteSize?
    public var disk: ByteSize?
    /// Shares to add (`--share`), after `removeShares` are removed.
    public var addShares: [VMShare]
    /// Shares to remove (`--unshare`), each a name or an absolute path (`VMShare.unshareTarget`).
    public var removeShares: [String]

    public init(cpus: Int? = nil, memory: ByteSize? = nil, disk: ByteSize? = nil, addShares: [VMShare] = [], removeShares: [String] = []) {
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.addShares = addShares
        self.removeShares = removeShares
    }

    public var isEmpty: Bool { cpus == nil && memory == nil && disk == nil && addShares.isEmpty && removeShares.isEmpty }

    /// What the host allows a VM, passed in so validation doesn't need the Virtualization framework.
    public struct Limits: Equatable, Sendable {
        public var cpus: ClosedRange<Int>
        public var memory: ClosedRange<UInt64>

        public init(cpus: ClosedRange<Int>, memory: ClosedRange<UInt64>) {
            self.cpus = cpus
            self.memory = memory
        }
    }

    /// The Virtualization framework sizes memory in whole megabytes.
    static let memoryGranularity: UInt64 = 1 << 20

    /// `config` with these settings applied. A larger disk marks the guest's container to grow at
    /// the next boot; the image itself is the caller's to resize. Unshares apply before shares, so
    /// one call can replace a share (e.g. to make it read-only); each new share's folder must exist.
    public func applied(to config: VMConfig, limits: Limits) throws -> VMConfig {
        if isEmpty { throw VMSettingsError.nothingToChange }
        var updated = config
        if let cpus {
            guard limits.cpus.contains(cpus) else { throw VMSettingsError.cpusOutOfRange(cpus, limits.cpus) }
            updated.cpus = cpus
        }
        if let memory {
            guard limits.memory.contains(memory.bytes) else { throw VMSettingsError.memoryOutOfRange(memory, limits.memory) }
            guard memory.bytes % Self.memoryGranularity == 0 else { throw VMSettingsError.memoryNotWholeMegabytes(memory) }
            updated.memory = memory.bytes
        }
        if let disk {
            guard disk.bytes >= config.disk else { throw VMSettingsError.diskShrink(current: ByteSize(bytes: config.disk), requested: disk) }
            if disk.bytes > config.disk {
                updated.disk = disk.bytes
                updated.diskGrowPending = true
            }
        }
        for target in removeShares {
            guard updated.shares.contains(where: { $0.matches(target) }) else { throw VMShareError.unknown(target) }
            updated.shares.removeAll { $0.matches(target) }
        }
        if !addShares.isEmpty { try VMShare.checkSupported(on: config.os) }
        for share in addShares { try share.checkFolder() }
        updated.shares += addShares
        try VMShare.checkNames(updated.shares)
        return updated
    }
}

public enum VMSettingsError: Error, Equatable, CustomStringConvertible {
    case nothingToChange
    case cpusOutOfRange(Int, ClosedRange<Int>)
    case memoryOutOfRange(ByteSize, ClosedRange<UInt64>)
    case memoryNotWholeMegabytes(ByteSize)
    case diskShrink(current: ByteSize, requested: ByteSize)
    case notConfigurable(String, String)

    public var description: String {
        switch self {
        case .nothingToChange: "nothing to change: give at least one of --cpus, --memory, --disk, --share or --unshare"
        case .cpusOutOfRange(let cpus, let range):
            "\(cpus) CPUs is outside what this host allows (\(range.lowerBound)–\(range.upperBound))"
        case .memoryOutOfRange(let memory, let range):
            "\(memory) memory is outside what this host allows (\(ByteSize(bytes: range.lowerBound))–\(ByteSize(bytes: range.upperBound)))"
        case .memoryNotWholeMegabytes(let memory): "memory must be a whole number of megabytes, not \(memory)"
        case .diskShrink(let current, let requested):
            "the disk can only grow (it is \(current), asked for \(requested)); the guest's freed space already returns to the host"
        case .notConfigurable(let name, let reason): "can't change \(name): \(reason)"
        }
    }
}
