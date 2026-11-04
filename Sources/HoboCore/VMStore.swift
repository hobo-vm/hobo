import CryptoKit
import Foundation

/// The VMs on this host: one visible bundle per VM, `<directory>/<name>.hobovm`, in `~/Hobo`
/// (`HOBO_VMS` overrides it). A bundle being built holds a `building` marker with the creating
/// process's PID; `config.json` is written only once the build succeeds. A VM runs as a launchd
/// job (see `VMJob`), and launchd's job table says whether it is running.
public struct VMStore: Sendable {
    public static let bundleExtension = "hobovm"
    public static let configFile = "config.json"
    public static let recipeFile = "recipe.toml"
    public static let buildingMarker = "building"
    /// Written by an ephemeral VM's process as it boots. From then on the VM is deleted as soon as
    /// it has neither a process nor saved state (`removeIfEphemeral`); until then, a clone made
    /// with `clone --ephemeral` stays, stopped, waiting for its first start.
    public static let startedMarker = "started"

    public var directory: URL
    /// Where the VM processes' sockets, logs and plists live.
    public var home: HoboHome
    public var launchd: Launchd

    public init(directory: URL, home: HoboHome = .standard(), launchd: Launchd = .system) {
        self.directory = directory
        self.home = home
        self.launchd = launchd
    }

    public static func standard() -> VMStore {
        if let override = ProcessInfo.processInfo.environment["HOBO_VMS"], !override.isEmpty {
            return VMStore(directory: URL(filePath: override, directoryHint: .isDirectory))
        }
        return VMStore(directory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Hobo"))
    }

    public enum Status: Equatable, Sendable {
        case stopped(VMConfig)
        /// Its VM process (`hobo _vm-run`) is running under launchd.
        case running(VMConfig, pid: Int32)
        /// Not running, with saved state that `start` resumes (`hobo suspend`).
        case suspended(VMConfig, SavedState)
        /// Its VM process last exited with a nonzero status; cleared by the next `start` or `stop`.
        case crashed(VMConfig, exitStatus: Int32)
        /// Being built by a live process.
        case building(pid: Int32)
        /// Its build process died without finishing or cleaning up.
        case failed
        /// Neither a `config.json` that decodes nor a `building` marker.
        case broken
    }

    public struct VM: Sendable {
        public var name: String
        public var bundle: URL
        public var status: Status
        /// Bytes the bundle occupies on the host.
        public var allocatedBytes: UInt64
        /// The VM's launchd job, if it is loaded.
        public var job: Launchd.Job?
    }

    public func bundle(for name: String) -> URL {
        directory.appending(path: "\(name).\(Self.bundleExtension)", directoryHint: .isDirectory)
    }

    /// Every VM, sorted by name. Anything in `directory` that isn't a `.hobovm` is ignored. An
    /// ephemeral VM that has stopped is deleted rather than listed (`removeIfEphemeral`).
    public func list() -> [VM] {
        let jobs = launchd.jobs()
        return names().sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { vm(named: $0, jobs: jobs) }
    }

    /// The VM called `name`, matched case-insensitively. An ephemeral VM that has stopped is
    /// deleted, and so not found (`removeIfEphemeral`).
    public func find(_ name: String) throws -> VM {
        guard let existing = existingName(matching: name), let vm = vm(named: existing, jobs: launchd.jobs()) else {
            throw VMStoreError.notFound(name)
        }
        return vm
    }

    /// The launchd job and files of the VM process for `name`. They are keyed by this store's
    /// directory as well as the name, so two stores (`HOBO_VMS`) can each run a VM called `dev`.
    public func job(for name: String) -> VMJob {
        // realpath, not resolvingSymlinksInPath, which strips /private and so isn't canonical.
        let path = realpath(directory.path, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? directory.standardizedFileURL.path
        let key = "\(Self.sha256(Data(path.utf8)).prefix(8)).\(name)"
        return VMJob(
            label: Launchd.labelPrefix + key,
            socket: home.root.appending(path: "\(key).sock"),
            log: home.root.appending(path: "\(key).log"),
            plist: home.root.appending(path: "launchd/\(key).plist")
        )
    }

    /// Unloads a VM's leftover job (one that has exited) and removes its files, for a VM that is
    /// going away or changing name.
    public func forgetJob(of name: String) {
        let job = job(for: name)
        launchd.bootout(job.label)
        for file in [job.plist, job.socket, job.log] { try? FileManager.default.removeItem(at: file) }
    }

    /// Starts a build: checks the name is valid and free, creates the bundle and marks it as
    /// being built by this process. Pair with `finishCreate` or `abandonCreate`.
    public func beginCreate(_ name: String) throws -> URL {
        try Self.validate(name)
        if let existing = existingName(matching: name) { throw VMStoreError.exists(existing) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = bundle(for: name)
        // Not intermediate: fails if a racing create made the bundle first.
        do {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            throw VMStoreError.exists(name)
        }
        do {
            try String(getpid()).write(to: bundle.appending(path: Self.buildingMarker), atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw error
        }
        return bundle
    }

    /// Records the finished VM: its recipe, its config, and then clears the building marker.
    public func finishCreate(_ name: String, config: VMConfig, recipe: Data) throws {
        let bundle = bundle(for: name)
        try recipe.write(to: bundle.appending(path: Self.recipeFile), options: .atomic)
        try config.write(to: bundle.appending(path: Self.configFile))
        try FileManager.default.removeItem(at: bundle.appending(path: Self.buildingMarker))
    }

    /// Deletes a failed or interrupted build's bundle.
    public func abandonCreate(_ name: String) throws {
        try FileManager.default.removeItem(at: bundle(for: name))
    }

    /// Throws if `vm` is being built, running (unless `allowRunning`), or holding saved state
    /// (unless `allowSuspended`).
    /// Saved state fits only the disk, configuration and platform identity it was saved with, so
    /// anything that changes those must refuse a suspended VM. Only operations that move or remove
    /// the bundle as a unit (delete, rename, discard) pass `allowSuspended`. `allowRunning` is for a
    /// caller about to power the VM off (`delete --force`).
    public func checkStopped(_ vm: VM, allowSuspended: Bool = false, allowRunning: Bool = false) throws {
        if case .building = vm.status { throw VMStoreError.busy(vm.name, reason: "being built") }
        // The job, not the status: a running VM whose config.json has gone bad still runs.
        if !allowRunning, vm.job?.pid != nil { throw VMStoreError.busy(vm.name, reason: "running (hobo stop \(vm.name))") }
        if !allowSuspended, case .suspended = vm.status {
            throw VMStoreError.busy(vm.name, reason: "suspended (hobo discard \(vm.name) throws its saved state away)")
        }
    }

    /// `hobo discard`: deletes a suspended VM's saved state, leaving it stopped. Returns false if
    /// it had none.
    @discardableResult
    public func discard(_ name: String) throws -> Bool {
        let vm = try find(name)
        try checkStopped(vm, allowSuspended: true)
        guard case .suspended = vm.status else { return false }
        try FileManager.default.removeItem(at: SavedState.directory(in: vm.bundle))
        return true
    }

    public func delete(_ name: String) throws {
        let vm = try find(name)
        try checkStopped(vm, allowSuspended: true)
        forgetJob(of: vm.name)
        try FileManager.default.removeItem(at: vm.bundle)
    }

    public func rename(_ old: String, to new: String) throws {
        let vm = try find(old)
        try Self.validate(new)
        // A case-only rename matches the VM itself, which is fine.
        if let existing = existingName(matching: new), existing != vm.name { throw VMStoreError.exists(existing) }
        try checkStopped(vm, allowSuspended: true)
        try FileManager.default.moveItem(at: vm.bundle, to: bundle(for: new))
        forgetJob(of: vm.name)
    }

    /// `hobo clone` (decision 12): a new VM `destination` from the stopped VM `source`, with its
    /// recipe and `config.json` but a new MAC (`macAddress`), and `ephemeral` as asked. `copy`
    /// copies the platform files from the source bundle to the new one and gives the new one its
    /// own machine identifier; it is HoboVM's, which knows each guest OS's files. The new bundle is
    /// marked as being built until it is complete, and deleted if anything fails.
    public func clone(
        _ source: String, to destination: String, ephemeral: Bool, macAddress: String,
        log: (String) -> Void, copy: (_ from: URL, _ to: URL, VMConfig) throws -> Void
    ) throws -> VM {
        let vm = try find(source)
        try checkStopped(vm)
        let config: VMConfig
        switch vm.status {
        case .stopped(let stored), .crashed(let stored, _): config = stored
        case .running, .building, .suspended: preconditionFailure("checkStopped refuses a running, building or suspended VM")
        case .failed: throw VMStoreError.notClonable(vm.name, "its build failed (hobo delete \(vm.name))")
        case .broken: throw VMStoreError.notClonable(vm.name, "its bundle has no valid \(Self.configFile)")
        }
        if config.os == .linux, !config.nicMatchedByDriver {
            throw VMStoreError.notClonable(
                vm.name, "its guest finds its network card by MAC, so a clone would have no network; create it again to clone it"
            )
        }
        let recipe = try Data(contentsOf: vm.bundle.appending(path: Self.recipeFile))
        let bundle = try beginCreate(destination)
        do {
            if !Self.sameVolume(vm.bundle, directory) {
                log("warning: \(vm.name)'s bundle is on another volume, so cloning it is a full copy of its disk")
            }
            try copy(vm.bundle, bundle, config)
            var cloned = config
            cloned.macAddress = macAddress
            cloned.created = .now
            cloned.ephemeral = ephemeral
            try finishCreate(destination, config: cloned, recipe: recipe)
        } catch {
            try? abandonCreate(destination)
            throw error
        }
        return try find(destination)
    }

    /// The length of what `ephemeralName` adds to the source's name, `-` and 4 hex digits: all that
    /// tells clones of one source apart.
    public static let ephemeralSuffixLength = 5

    /// A free name for an ephemeral clone of `source`: `<source>-<4 hex digits>`, the source's name
    /// shortened if need be to stay within a name's 63 characters.
    public func ephemeralName(for source: String) throws -> String {
        let base = String(source.prefix(63 - Self.ephemeralSuffixLength))
        for _ in 0..<100 {
            let name = "\(base)-\(String(format: "%04x", UInt16.random(in: .min ... .max)))"
            if existingName(matching: name) == nil { return name }
        }
        throw VMStoreError.exists("\(base)-*")
    }

    /// The one place an ephemeral VM is deleted (decision 12): once it has booted (`startedMarker`),
    /// whenever it has no saved state and no process. Its VM process calls this as it exits, and
    /// the store as it reads a VM (`find`, `list`), so a VM whose process was killed, crashed, or
    /// went with a host reboot, or whose saved state was discarded, goes the next time anything
    /// looks at it. Deletes the bundle and the job's plist and socket, unless it is suspended or no
    /// longer ephemeral (`hobo set --keep`). With `keepLog` (a failed run), the job's log stays so
    /// a start that failed can still show why; an auto-named clone's name never comes back, so a
    /// clean run's log would otherwise pile up. The job stays loaded, as an exited one does, until
    /// the next start (or a stop) unloads it. Returns whether it deleted anything.
    @discardableResult
    public func removeIfEphemeral(_ name: String, keepLog: Bool) -> Bool {
        let bundle = bundle(for: name)
        guard let config = try? VMConfig.load(from: bundle.appending(path: Self.configFile)), config.ephemeral,
              FileManager.default.fileExists(atPath: bundle.appending(path: Self.startedMarker).path),
              SavedState.load(in: bundle) == nil
        else { return false }
        let job = job(for: name)
        for file in [bundle, job.plist, job.socket] + (keepLog ? [] : [job.log]) { try? FileManager.default.removeItem(at: file) }
        return true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> (any NSObjectProtocol & NSCopying)? {
            try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        guard let first = volume(a), let second = volume(b) else { return true }
        return first.isEqual(second)
    }

    /// A VM name is a filename, a launchd label suffix and a socket name, so it is kept plain.
    public static func validate(_ name: String) throws {
        guard name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,62}/) != nil else {
            throw VMStoreError.invalidName(name)
        }
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).hexString }

    private func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let suffix = ".\(Self.bundleExtension)"
        return entries.filter { $0.hasSuffix(suffix) && $0.count > suffix.count }.map { String($0.dropLast(suffix.count)) }
    }

    /// Names collide case-insensitively, as on the default APFS, even on a case-sensitive volume.
    private func existingName(matching name: String) -> String? {
        names().first { $0.lowercased() == name.lowercased() }
    }

    /// Nil for an ephemeral VM that has stopped, which this deletes.
    private func vm(named name: String, jobs: [String: Launchd.Job]) -> VM? {
        let bundle = bundle(for: name)
        let job = jobs[job(for: name).label]
        let status = status(of: bundle, job: job)
        // Stopped or crashed means no process and no saved state, so an ephemeral VM that has booted
        // is deleted here, keeping a crash's log as its process would have.
        let keepLog: Bool? = switch status {
        case .stopped: false
        case .crashed: true
        default: nil
        }
        if let keepLog, removeIfEphemeral(name, keepLog: keepLog) { return nil }
        return VM(name: name, bundle: bundle, status: status, allocatedBytes: Self.bundleBytes(of: bundle), job: job)
    }

    private func status(of bundle: URL, job: Launchd.Job?) -> Status {
        let marker = bundle.appending(path: Self.buildingMarker)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let text = try? String(contentsOf: marker, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let written = try? marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Self.isBuilder(pid, markerWritten: written)
            else { return .failed }
            return .building(pid: pid)
        }
        guard let config = try? VMConfig.load(from: bundle.appending(path: Self.configFile)) else { return .broken }
        if let pid = job?.pid { return .running(config, pid: pid) }
        // Ahead of crashed: a VM process that failed to resume leaves the state for another try.
        if let saved = SavedState.load(in: bundle) { return .suspended(config, saved) }
        if let job, job.lastExitStatus != 0 { return .crashed(config, exitStatus: job.lastExitStatus) }
        return .stopped(config)
    }

    /// Whether `pid` is still the process that wrote the marker. A PID can be reused (after a reboot,
    /// say) by a process that started after the marker was written, which must not keep the VM busy.
    private static func isBuilder(_ pid: Int32, markerWritten: Date) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let start = info.kp_proc.p_starttime
        let started = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return started <= markerWritten
    }

    /// Bytes a VM's bundle occupies. Of its snapshots only the saved state counts: their platform
    /// files are clones, whose blocks the VM's own files already count until they diverge. How far
    /// they have diverged isn't something a file's size can say, so it goes uncounted.
    static func bundleBytes(of bundle: URL) -> UInt64 {
        allocatedBytes(of: bundle, excluding: Snapshot.directoryName)
            + Snapshot.list(in: bundle).reduce(0) { $0 + ($1.savedStateBytes ?? 0) }
    }

    /// Bytes `directory` occupies on the host, leaving out any top-level entry named `excluded`.
    static func allocatedBytes(of directory: URL, excluding excluded: String? = nil) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in files {
            if files.level == 1, file.lastPathComponent == excluded {
                files.skipDescendants()
                continue
            }
            total += UInt64((try? file.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// A VM process's launchd job and the files in `~/.hobo` that go with it.
public struct VMJob: Equatable, Sendable {
    public var label: String
    /// The control socket the VM process serves (see `HoboControl`).
    public var socket: URL
    /// The VM process's stdout and stderr.
    public var log: URL
    public var plist: URL
}

public enum VMStoreError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case exists(String)
    case notFound(String)
    case busy(String, reason: String)
    case notClonable(String, String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            "invalid VM name \"\(name)\" (letters, digits, '.', '_' and '-', starting with a letter or digit, at most 63)"
        case .exists(let name): "a VM named \"\(name)\" already exists (hobo delete \(name) to replace it)"
        case .notFound(let name): "no VM named \"\(name)\""
        case .busy(let name, let reason): "VM \"\(name)\" is \(reason)"
        case .notClonable(let name, let reason): "can't clone \(name): \(reason)"
        }
    }
}
