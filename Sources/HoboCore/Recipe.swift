import Foundation
import TOMLKit

/// A VM recipe, conventionally `Hobo.toml`: the source, default hardware and `[[provision]]` steps
/// to build a VM from. It holds no host-specific state, so it can be handed to someone else.
public struct Recipe: Equatable, Sendable {
    /// The file `hobo init` writes and `hobo validate` reads by default.
    public static let fileName = "Hobo.toml"
    public static let defaultCPUs = 4
    public static let defaultMemory = ByteSize(bytes: 8 << 30)
    public static let defaultDisk = ByteSize(bytes: 80 << 30)

    public var cpus: Int
    public var memory: ByteSize
    public var disk: ByteSize
    public var source: Source
    public var provisioners: [Provisioner]
    /// The recipe's directory; relative `path`/`source` values resolve against it.
    public var directory: URL

    public enum Source: Equatable, Sendable {
        /// The newest IPSW this host supports. Unpinned, so builds warn.
        case latest
        case remote(URL, sha256: String)
        case local(URL, sha256: String)

        public var isPinned: Bool { self != .latest }
    }

    public static func parse(_ toml: String, directory: URL) throws -> Recipe {
        let raw = try TOMLDecoder().decode(RawRecipe.self, from: toml)
        if raw.guiTesting?.enabled == true { throw RecipeError.guiTestingNotImplemented }

        let recipe = Recipe(
            cpus: raw.cpus ?? defaultCPUs,
            memory: raw.memory ?? defaultMemory,
            disk: raw.disk ?? defaultDisk,
            source: try source(from: raw.source, directory: directory),
            provisioners: raw.provision ?? [],
            directory: directory
        )
        // Caught here rather than by diskutil or VZ after the IPSW download.
        if recipe.cpus < 1 { throw RecipeError.invalidHardware("cpus must be at least 1") }
        if recipe.memory.bytes == 0 { throw RecipeError.invalidHardware("memory must be more than 0") }
        if recipe.disk.bytes == 0 { throw RecipeError.invalidHardware("disk must be more than 0") }
        for (index, step) in recipe.provisioners.enumerated() {
            if let problem = step.problem { throw RecipeError.invalidProvisioner(index, problem) }
        }
        return recipe
    }

    public static func load(from url: URL) throws -> Recipe {
        try parse(String(contentsOf: url, encoding: .utf8), directory: url.deletingLastPathComponent())
    }

    public func resolve(_ path: String) -> URL { resolveHostPath(path, relativeTo: directory) }

    /// Host files the recipe refers to that do not exist. Checked by `hobo validate` and
    /// before a build, so a typo fails in seconds instead of after a 30-minute install.
    public func missingFiles() -> [String] {
        var paths = provisioners.compactMap(\.hostFile)
        if case .local(let url, _) = source { paths.append(url.path) }
        return paths.filter { !FileManager.default.fileExists(atPath: resolve($0).path) }
    }

    public func checkFilesExist() throws {
        let missing = missingFiles()
        if !missing.isEmpty { throw RecipeError.missingFiles(missing) }
    }

    private static func source(from raw: RawRecipe.RawSource, directory: URL) throws -> Source {
        if raw.ipsw == "latest" { return .latest }
        guard let sha = raw.sha256?.lowercased() else { throw RecipeError.missingSHA256(raw.ipsw) }
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw RecipeError.invalidSHA256(sha) }
        if let url = URL(string: raw.ipsw), url.scheme == "https" || url.scheme == "http" {
            return .remote(url, sha256: sha)
        }
        return .local(resolveHostPath(raw.ipsw, relativeTo: directory), sha256: sha)
    }
}

public enum RecipeError: Error, Equatable, CustomStringConvertible {
    case invalidSize(String)
    case missingSHA256(String)
    case invalidSHA256(String)
    case invalidHardware(String)
    case invalidProvisioner(Int, String)
    case guiTestingNotImplemented
    case missingFiles([String])

    public var description: String {
        switch self {
        case .invalidSize(let value): "invalid size \"\(value)\" (expected e.g. \"512MB\" or \"8GB\")"
        case .missingSHA256(let ipsw): "source \"\(ipsw)\" needs a sha256 (only ipsw = \"latest\" may omit it)"
        case .invalidSHA256(let sha): "invalid sha256 \"\(sha)\" (expected 64 hex digits)"
        case .invalidHardware(let reason): reason
        case .invalidProvisioner(let index, let reason): "provision step \(index + 1): \(reason)"
        case .guiTestingNotImplemented: "[gui_testing] is not implemented yet"
        case .missingFiles(let paths): "recipe refers to missing files: \(paths.joined(separator: ", "))"
        }
    }
}

private struct RawRecipe: Decodable {
    struct RawSource: Decodable {
        var ipsw: String
        var sha256: String?
    }

    struct GUITesting: Decodable {
        var enabled: Bool?
    }

    var cpus: Int?
    var memory: ByteSize?
    var disk: ByteSize?
    var source: RawSource
    var guiTesting: GUITesting?
    var provision: [Provisioner]?

    private enum CodingKeys: String, CodingKey {
        case cpus, memory, disk, source, provision
        case guiTesting = "gui_testing"
    }
}
