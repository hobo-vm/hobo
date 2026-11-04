import Foundation
import HoboControl
import HoboCore

extension VMLifecycle {
    /// `hobo snapshot save` (decision 13). A running VM's process pauses it, saves its state, clones
    /// its disk and resumes it; a suspended VM's state and disk are cloned as they lie, and a stopped
    /// VM's disk alone. Neither of those two touches the VM.
    public func saveSnapshot(_ name: String, tag: String, timeout: Duration = .seconds(5 * 60)) async throws -> Snapshot {
        let vm = try store.find(name)
        try Snapshot.validate(tag)
        let config: VMConfig
        var running = false
        switch vm.status {
        case .running(let stored, _):
            config = stored
            running = true
        case .stopped(let stored), .crashed(let stored, _), .suspended(let stored, _):
            config = stored
        case .building: throw VMStoreError.busy(vm.name, reason: "being built")
        case .failed: throw SnapshotError.notSnapshottable(vm.name, "its build failed (hobo delete \(vm.name))")
        case .broken: throw SnapshotError.notSnapshottable(vm.name, "its bundle has no valid \(VMStore.configFile)")
        }
        // Stopping would delete it, and its snapshots with it, so restore could never work.
        if config.ephemeral { throw SnapshotError.ephemeral(vm.name) }
        if running {
            try await askProcessToSnapshot(vm.name, tag: tag, timeout: timeout)
        } else {
            try store.snapshotAtRest(vm.bundle, tag: tag, config: config)
        }
        return try Snapshot.find(tag, in: vm.bundle)
    }

    private func askProcessToSnapshot(_ name: String, tag: String, timeout: Duration) async throws {
        let response: ControlResponse
        do {
            // The answer comes once the VM is running again, which takes a while for a large memory.
            response = try await ControlClient.send(.snapshot(tag: tag), to: store.job(for: name).socket, timeout: timeout)
        } catch {
            throw LifecycleError.unresponsive(name, String(describing: error))
        }
        switch response {
        case .accepted: return
        case .error(let message): throw LifecycleError.refused(name, message)
        default: throw ControlError.badMessage("expected an acknowledgement, got \(response)")
        }
    }

    /// What `snapshot restore` left the VM doing.
    public enum RestoreResult: Equatable, Sendable {
        /// A disk-only snapshot, which leaves the VM stopped, as it was then.
        case stopped
        /// A live snapshot: resumed, or booted from its disk if its state no longer fits the VM.
        case started(StartResult)
    }

    /// `hobo snapshot restore` (decision 13): puts the snapshot's files back and leaves the VM as
    /// it was when they were saved. A live snapshot's state becomes the VM's saved state, so `start`
    /// resumes it as it would any suspended VM. The snapshot itself is untouched and can be restored
    /// again. A running or suspended VM has something to lose, so it takes `force`, which powers it
    /// off or discards its state; a stopped VM's disk is simply replaced.
    public func restoreSnapshot(_ name: String, tag: String, force: Bool, timeout: Duration = .seconds(10 * 60)) async throws -> RestoreResult {
        let vm = try store.find(name)
        let snapshot = try Snapshot.find(tag, in: vm.bundle)
        switch vm.status {
        case .running:
            guard force else { throw SnapshotError.needsForce(vm.name, tag: snapshot.tag, state: "running") }
            _ = try await stop(vm.name, force: true)
        case .suspended:
            guard force else { throw SnapshotError.needsForce(vm.name, tag: snapshot.tag, state: "suspended") }
        case .stopped, .crashed: break
        case .building: throw VMStoreError.busy(vm.name, reason: "being built")
        case .failed: throw SnapshotError.notSnapshottable(vm.name, "its build failed (hobo delete \(vm.name))")
        case .broken: throw SnapshotError.notSnapshottable(vm.name, "its bundle has no valid \(VMStore.configFile)")
        }
        try store.restoreFiles(of: snapshot, into: vm.bundle, log: log)
        // A crashed run's exit status, or a failed resume's, would show the restored VM as crashed.
        store.launchd.bootout(store.job(for: vm.name).label)
        log("Restored \(vm.name) to \(snapshot.tag)")
        guard snapshot.isLive else { return .stopped }
        return .started(try await start(vm.name, timeout: timeout))
    }
}

extension VMLifecycle.RestoreResult: Encodable {
    private enum CodingKeys: String, CodingKey { case outcome }

    /// `{"outcome": "stopped"}`, or a `StartResult`'s `{"outcome": "resumed" | "started", "status": {...}}`.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .stopped:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("stopped", forKey: .outcome)
        case .started(let result):
            try result.encode(to: encoder)
        }
    }
}

extension VMStore {
    /// The folder a restore assembles its files in, so running out of space fails before anything
    /// of the VM's is replaced.
    static let restoringDirectory = "restoring"

    /// Snapshots a VM with no process: its platform files, and its saved state if it is suspended.
    func snapshotAtRest(_ bundle: URL, tag: String, config: VMConfig) throws {
        let partial = try Snapshot.begin(tag, in: bundle)
        do {
            try vmBundle(at: bundle, os: config.os).copyPlatformFiles(to: partial)
            if SavedState.load(in: bundle) != nil { try Self.cloneSavedState(from: bundle, to: partial) }
            try Snapshot.finish(tag, partial: partial, in: bundle, config: config)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Replaces the VM's platform files, saved state and disk settings with the snapshot's. The disk
    /// goes back to its size then, while CPUs and memory stay as they are now; if those have changed,
    /// the snapshot's state doesn't fit, and the VM has only the disk to boot from.
    ///
    /// The saved state goes in last: a crash before then leaves a stopped VM, not one that would
    /// resume memory onto a disk it doesn't match.
    func restoreFiles(of snapshot: Snapshot, into bundle: URL, log: (String) -> Void) throws {
        let configFile = bundle.appending(path: Self.configFile)
        var config = try VMConfig.load(from: configFile)
        let source = Snapshot.directory(snapshot.tag, in: bundle)
        let restoring = bundle.appending(path: Self.restoringDirectory, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: restoring)
        try FileManager.default.createDirectory(at: restoring, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: restoring) }

        let restoresState = snapshot.isLive && snapshot.record.savedStateFits(config)
        if snapshot.isLive && !restoresState {
            log(
                "warning: \(snapshot.tag) was saved with \(snapshot.record.cpus) CPUs and \(ByteSize(bytes: snapshot.record.memory)) "
                    + "of memory, and the VM now has \(config.cpus) and \(ByteSize(bytes: config.memory)), so its saved state "
                    + "can't be used; booting from its disk, as after a power loss"
            )
        }
        let snapshotBundle = try vmBundle(at: source, os: config.os)
        try snapshotBundle.copyPlatformFiles(to: restoring)
        if restoresState { try Self.cloneSavedState(from: source, to: restoring) }

        // Nothing failed for want of space, so now the VM's own files can go. A saved state that
        // stayed would resume onto a disk it doesn't match, so failing to remove it ends the restore.
        let savedState = SavedState.directory(in: bundle)
        if FileManager.default.fileExists(atPath: savedState.path) { try FileManager.default.removeItem(at: savedState) }
        try? FileManager.default.removeItem(at: SavedState.partialDirectory(in: bundle))
        for name in type(of: snapshotBundle).platformFiles {
            try Self.replace(bundle.appending(path: name), with: restoring.appending(path: name))
        }
        if config.disk != snapshot.record.disk {
            log("The disk is back to \(ByteSize(bytes: snapshot.record.disk)), as it was then; hobo set --disk grows it again")
        }
        config.disk = snapshot.record.disk
        config.diskGrowPending = snapshot.record.diskGrowPending
        try config.write(to: configFile)
        if restoresState {
            try Self.replace(SavedState.directory(in: bundle), with: SavedState.directory(in: restoring))
        }
    }

    /// Clones a saved state from one folder holding a `suspended/` to another.
    private static func cloneSavedState(from source: URL, to destination: URL) throws {
        let from = SavedState.directory(in: source)
        let to = SavedState.directory(in: destination)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false)
        for name in [SavedState.stateFile, SavedState.runFile] {
            try cloneFile(from.appending(path: name), to: to.appending(path: name))
        }
    }

    private static func replace(_ target: URL, with replacement: URL) throws {
        guard Foundation.rename(replacement.path, target.path) == 0 else {
            throw VMError.replaceFailed(target.lastPathComponent, String(cString: strerror(errno)))
        }
    }
}
