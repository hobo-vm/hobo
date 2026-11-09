import Foundation
import HoboCore

/// The detail pane's settings, as edited: what `hobo set` can change. `settings(from:)` turns the
/// edits into the `VMSettings` the CLI would build, so the GUI changes a VM exactly as `set` does.
public struct SettingsForm: Equatable, Sendable {
    public var cpus: Int
    /// Whole gigabytes: what the form offers. A VM made with a size in megabytes keeps it until edited.
    public var memoryGB: Int
    public var diskGB: Int
    public var shares: [VMShare]
    /// An ephemeral VM's "Keep" toggle; a kept VM can't go back to ephemeral.
    public var keep: Bool

    static let gigabyte: UInt64 = 1 << 30

    public init(_ config: VMConfig) {
        cpus = config.cpus
        memoryGB = Self.wholeGigabytes(config.memory)
        diskGB = Self.wholeGigabytes(config.disk)
        shares = config.shares
        keep = !config.ephemeral
    }

    private static func wholeGigabytes(_ bytes: UInt64) -> Int { Int((bytes + gigabyte / 2) / gigabyte) }

    /// Adds a share of `folder`, picked in Add Folder…. Throws, adding nothing, if its name can't
    /// mount or another share already mounts under it, which would leave two rows of one name.
    public mutating func share(_ folder: URL) throws {
        let share = try VMShare.parse(folder.path(percentEncoded: false), currentDirectory: URL(filePath: "/"))
        try VMShare.checkNames(shares + [share])
        shares.append(share)
    }

    /// The change from `config` that these edits make; empty if there is none.
    public func settings(from config: VMConfig) -> VMSettings {
        let original = SettingsForm(config)
        var settings = VMSettings()
        if cpus != original.cpus { settings.cpus = cpus }
        if memoryGB != original.memoryGB { settings.memory = ByteSize(bytes: UInt64(memoryGB) * Self.gigabyte) }
        if diskGB != original.diskGB { settings.disk = ByteSize(bytes: UInt64(diskGB) * Self.gigabyte) }
        // A share edited in place (made read-only, say) is removed and added again, as
        // `--unshare src --share ~/src:ro` does: unshares apply first.
        settings.removeShares = config.shares.filter { !shares.contains($0) }.map(\.name)
        settings.addShares = shares.filter { !config.shares.contains($0) }
        settings.keep = keep && config.ephemeral
        return settings
    }

    /// What can be edited for a VM in a given state, following `VMSettings.apply`: the machine only
    /// when stopped (or crashed), `keep` whenever the VM is built and usable.
    public struct Editable: Equatable, Sendable {
        public var machine: Bool
        public var keep: Bool
        /// Why the machine settings are locked, if they are.
        public var reason: String?
    }

    public static func editable(_ summary: VMSummary) -> Editable {
        switch summary.state {
        case .stopped, .crashed: Editable(machine: true, keep: true)
        case .running: Editable(machine: false, keep: true, reason: "Stop \(summary.name) to change these.")
        case .suspended:
            Editable(machine: false, keep: true, reason: "\(summary.name) is suspended: start and stop it, or discard its saved state, to change these.")
        case .building: Editable(machine: false, keep: false, reason: "\(summary.name) is being built.")
        case .failed, .broken: Editable(machine: false, keep: false, reason: "\(summary.name) can't be changed: delete it.")
        }
    }
}
