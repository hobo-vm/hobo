import Foundation

/// A host folder shared into the guest over virtio-fs. A macOS guest mounts every share at
/// `/Volumes/My Shared Files/<name>` (decision 9). Persistent shares live in `config.json`
/// (`hobo set --share`); `hobo start --share` adds one for a single run.
public struct VMShare: Codable, Equatable, Sendable {
    /// The folder's name in the guest: the host folder's basename.
    public var name: String
    /// Absolute and standardized.
    public var path: String
    public var readOnly: Bool

    public init(name: String, path: String, readOnly: Bool) {
        self.name = name
        self.path = path
        self.readOnly = readOnly
    }

    static let readOnlySuffix = ":ro"

    /// Parses a `--share` argument, `<folder>[:ro]`, resolving the folder against `currentDirectory`.
    public static func parse(_ argument: String, currentDirectory: URL) throws -> VMShare {
        var folder = argument
        let readOnly = folder.hasSuffix(readOnlySuffix)
        if readOnly { folder.removeLast(readOnlySuffix.count) }
        guard !folder.isEmpty else { throw VMShareError.emptyPath }
        let path = absolutePath(folder, currentDirectory: currentDirectory)
        let name = URL(filePath: path).lastPathComponent
        // `/` and `..` past the root standardize to the root, a volume root that can't be shared.
        guard path != "/", !name.isEmpty else { throw VMShareError.unusable(path, volumeRootProblem) }
        return VMShare(name: name, path: path, readOnly: readOnly)
    }

    /// The argument `parse` reads back, for passing a share to the VM process.
    public var argument: String { readOnly ? path + Self.readOnlySuffix : path }

    /// What `--unshare` names: a path (anything with a `/`) resolved to absolute, else a share's name.
    public static func unshareTarget(_ argument: String, currentDirectory: URL) -> String {
        argument.contains("/") ? absolutePath(argument, currentDirectory: currentDirectory) : argument
    }

    /// Whether `target` (from `unshareTarget`) names this share.
    public func matches(_ target: String) -> Bool {
        path == target || name.caseInsensitiveCompare(target) == .orderedSame
    }

    static let volumeRootProblem = "it is a volume root, which virtio-fs can't share (share a folder on it)"

    /// Throws if the host folder can't be shared right now.
    public func checkFolder() throws {
        if let problem = folderProblem { throw VMShareError.unusable(path, problem) }
    }

    /// Why the host folder can't be shared right now, or nil. virtio-fs takes only folders, and
    /// refuses volume roots.
    public var folderProblem: String? {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "it doesn't exist" }
        guard isDirectory.boolValue else { return "it is not a folder" }
        if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return Self.volumeRootProblem }
        return nil
    }

    /// `shares` whose folders can be shared now, logging a warning for each left out (a folder that
    /// has gone, such as an unplugged drive's, only loses its share for this run).
    public static func available(_ shares: [VMShare], log: (String) -> Void) -> [VMShare] {
        shares.filter { share in
            guard let problem = share.folderProblem else { return true }
            log("warning: not sharing \(share.name) this run: \(share.path): \(problem)")
            return false
        }
    }

    /// Characters virtio-fs refuses in a share's name. Finder shows `:` as `/`.
    static let forbiddenNameCharacters: Set<Character> = ["*", "/", ":", "<", ">", "?", "\\", "|"]

    /// Why virtio-fs would refuse this share's name (raising, not throwing, when the VM is built), or nil.
    var nameProblem: String? {
        if name.contains(where: Self.forbiddenNameCharacters.contains) {
            return "its name has a character a share can't (one of * / : < > ? \\ |); rename or symlink it"
        }
        if name.utf8.count > Int(NAME_MAX) { return "its name is longer than \(NAME_MAX) bytes" }
        return nil
    }

    /// Throws unless `os`'s guests can mount shares: only macOS's can yet (a Linux VM's
    /// configuration refuses them, so it would fail to boot).
    public static func checkSupported(on os: VMConfig.OS) throws {
        if os != .macOS { throw VMShareError.unsupported(os) }
    }

    /// Throws if a share's name can't mount in the guest, or two would mount at the same guest
    /// path. Names compare case-insensitively, as the guest's volume does.
    public static func checkNames(_ shares: [VMShare]) throws {
        var seen: [String: VMShare] = [:]
        for share in shares {
            if let problem = share.nameProblem { throw VMShareError.unusable(share.path, problem) }
            if let other = seen[share.name.lowercased()] {
                throw VMShareError.duplicateName(share.name, other.path, share.path)
            }
            seen[share.name.lowercased()] = share
        }
    }

    private static func absolutePath(_ path: String, currentDirectory: URL) -> String {
        resolveHostPath(path, relativeTo: currentDirectory).path(percentEncoded: false)
            .trimmingSuffix("/")
    }
}

private extension String {
    /// Drops trailing `suffix`es, leaving `/` itself alone.
    func trimmingSuffix(_ suffix: Character) -> String {
        var result = self
        while result.count > 1 && result.last == suffix { result.removeLast() }
        return result
    }
}

public enum VMShareError: Error, Equatable, CustomStringConvertible {
    case emptyPath
    case unusable(String, String)
    case duplicateName(String, String, String)
    case unknown(String)
    case unsupported(VMConfig.OS)

    public var description: String {
        switch self {
        case .emptyPath: "--share needs a folder"
        case .unusable(let path, let problem): "can't share \(path): \(problem)"
        case .duplicateName(let name, let first, let second):
            "\(first) and \(second) would both mount as \"\(name)\" in /Volumes/My Shared Files; rename or symlink one of them"
        case .unknown(let target): "no share named \(target)"
        case .unsupported(let os): "shared folders aren't supported on \(os.rawValue) VMs yet"
        }
    }
}
