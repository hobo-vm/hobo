import Foundation

/// A suspended VM's saved state (decision 11): the bundle's `suspended/` folder, holding VZ's
/// memory and device state and the run it came from. The VM process writes it into `suspending/`
/// and renames that into place, so `suspended/` exists only once complete; resuming deletes it
/// before the guest runs again, since the disk then moves on and the state no longer fits it.
public struct SavedState: Equatable, Sendable {
    public static let directoryName = "suspended"
    /// Where the VM process writes the state before it is complete.
    public static let partialDirectoryName = "suspending"
    public static let stateFile = "state.vzvmsave"
    public static let runFile = "run.json"

    /// Bytes the saved state occupies on the host.
    public var bytes: UInt64
    /// What `run.json` recorded, or nil if it doesn't decode.
    public var run: SuspendedRun?

    public init(bytes: UInt64, run: SuspendedRun?) {
        self.bytes = bytes
        self.run = run
    }

    public static func directory(in bundle: URL) -> URL {
        bundle.appending(path: directoryName, directoryHint: .isDirectory)
    }

    public static func partialDirectory(in bundle: URL) -> URL {
        bundle.appending(path: partialDirectoryName, directoryHint: .isDirectory)
    }

    /// The bundle's saved state, or nil if it isn't suspended.
    public static func load(in bundle: URL) -> SavedState? {
        let directory = directory(in: bundle)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return SavedState(
            bytes: VMStore.allocatedBytes(of: directory),
            run: try? SuspendedRun.load(from: directory.appending(path: runFile))
        )
    }
}

/// `run.json`: what a suspended run was configured with beyond `config.json`, so the resumed VM's
/// configuration matches the saved state's. VZ refuses to restore into any other.
public struct SuspendedRun: Codable, Equatable, Sendable {
    /// Every share the run had, persistent and run-only (`start --share`), as it had them.
    public var shares: [VMShare]
    public var suspendedAt: Date

    public init(shares: [VMShare], suspendedAt: Date) {
        self.shares = shares
        self.suspendedAt = suspendedAt
    }

    public static func load(from url: URL) throws -> SuspendedRun {
        try VMConfig.decoder.decode(SuspendedRun.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try VMConfig.encoder.encode(self).write(to: url, options: .atomic)
    }
}
