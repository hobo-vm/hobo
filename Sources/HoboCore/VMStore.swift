import CryptoKit
import Foundation

/// The VMs on this host: one visible bundle per VM, `<directory>/<name>.hobovm`, in `~/Hobo`
/// (`HOBO_VMS` overrides it). A bundle being built holds a `building` marker with the creating
/// process's PID; `config.json` is written only once the build succeeds.
public struct VMStore: Sendable {
    public static let bundleExtension = "hobovm"
    public static let configFile = "config.json"
    public static let recipeFile = "recipe.toml"
    public static let buildingMarker = "building"

    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func standard() -> VMStore {
        if let override = ProcessInfo.processInfo.environment["HOBO_VMS"], !override.isEmpty {
            return VMStore(directory: URL(filePath: override, directoryHint: .isDirectory))
        }
        return VMStore(directory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Hobo"))
    }

    public enum Status: Equatable, Sendable {
        case stopped(VMConfig)
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
    }

    public func bundle(for name: String) -> URL {
        directory.appending(path: "\(name).\(Self.bundleExtension)", directoryHint: .isDirectory)
    }

    /// Every VM, sorted by name. Anything in `directory` that isn't a `.hobovm` is ignored.
    public func list() -> [VM] {
        names().sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { vm(named: $0) }
    }

    /// The VM called `name`, matched case-insensitively.
    public func find(_ name: String) throws -> VM {
        guard let existing = existingName(matching: name) else { throw VMStoreError.notFound(name) }
        return vm(named: existing)
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
        try String(getpid()).write(to: bundle.appending(path: Self.buildingMarker), atomically: true, encoding: .utf8)
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

    /// Throws if `vm` is in use. Today only a live build counts; the VM process will too.
    public func checkNotRunning(_ vm: VM) throws {
        if case .building = vm.status { throw VMStoreError.busy(vm.name, reason: "being built") }
    }

    public func delete(_ name: String) throws {
        let vm = try find(name)
        try checkNotRunning(vm)
        try FileManager.default.removeItem(at: vm.bundle)
    }

    public func rename(_ old: String, to new: String) throws {
        let vm = try find(old)
        try Self.validate(new)
        // A case-only rename matches the VM itself, which is fine.
        if let existing = existingName(matching: new), existing != vm.name { throw VMStoreError.exists(existing) }
        try checkNotRunning(vm)
        try FileManager.default.moveItem(at: vm.bundle, to: bundle(for: new))
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

    private func vm(named name: String) -> VM {
        let bundle = bundle(for: name)
        return VM(name: name, bundle: bundle, status: status(of: bundle), allocatedBytes: Self.allocatedBytes(of: bundle))
    }

    private func status(of bundle: URL) -> Status {
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

    static func allocatedBytes(of bundle: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in files {
            total += UInt64((try? file.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

public enum VMStoreError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case exists(String)
    case notFound(String)
    case busy(String, reason: String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            "invalid VM name \"\(name)\" (letters, digits, '.', '_' and '-', starting with a letter or digit, at most 63)"
        case .exists(let name): "a VM named \"\(name)\" already exists (hobo delete \(name) to replace it)"
        case .notFound(let name): "no VM named \"\(name)\""
        case .busy(let name, let reason): "VM \"\(name)\" is \(reason)"
        }
    }
}
