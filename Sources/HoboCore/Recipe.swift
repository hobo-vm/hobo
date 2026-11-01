import Foundation
import TOMLKit

/// A box recipe for `hobo box build`. Hardware keys and `[[provision]]` steps use the Boxcar's
/// names and types; a step's `run` is ignored, since every step runs exactly once.
public struct Recipe: Equatable, Sendable {
    public static let defaultCPUs = 4
    public static let defaultMemory = ByteSize(bytes: 8 << 30)
    public static let defaultDisk = ByteSize(bytes: 80 << 30)

    public var name: String
    public var version: String
    public var description: String?
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
        try validateName(raw.name)
        try validateVersion(raw.version)
        if raw.guiTesting?.enabled == true { throw RecipeError.guiTestingNotImplemented }

        let recipe = Recipe(
            name: raw.name,
            version: raw.version,
            description: raw.description,
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
            try validate(step, index: index)
        }
        return recipe
    }

    public static func load(from url: URL) throws -> Recipe {
        try parse(String(contentsOf: url, encoding: .utf8), directory: url.deletingLastPathComponent())
    }

    /// `greg/macos-27` version `1.0.0` → `greg-macos-27-1.0.0`.
    public var slug: String { "\(name.replacingOccurrences(of: "/", with: "-"))-\(version)" }
    public var boxFileName: String { "\(slug).box" }

    public func resolve(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
    }

    /// Host files the recipe refers to that do not exist. Checked by `validate-recipe` and
    /// before a build, so a typo fails in seconds instead of after a 30-minute install.
    public func missingFiles() -> [String] {
        var paths = provisioners.compactMap { $0.type == .shell ? $0.path : $0.source }
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
        let path = (raw.ipsw as NSString).expandingTildeInPath
        return .local(URL(filePath: path, relativeTo: directory).standardizedFileURL, sha256: sha)
    }

    private static let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))

    private static func validateName(_ name: String) throws {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(nameCharacters.contains) })
        else { throw RecipeError.invalidName(name) }
    }

    /// The version names the build's working directory and the `.box`, so it must not carry a path.
    private static func validateVersion(_ version: String) throws {
        if version.isEmpty { throw RecipeError.missingVersion }
        guard version.unicodeScalars.allSatisfy(nameCharacters.union(CharacterSet(charactersIn: "+")).contains) else {
            throw RecipeError.invalidVersion(version)
        }
    }

    private static func validate(_ step: Provisioner, index: Int) throws {
        switch step.type {
        case .shell where (step.inline == nil) == (step.path == nil):
            throw RecipeError.invalidProvisioner(index, "shell needs exactly one of inline or path")
        case .file where step.source == nil || step.destination == nil:
            throw RecipeError.invalidProvisioner(index, "file needs source and destination")
        default:
            break
        }
    }
}

public enum RecipeError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case missingVersion
    case invalidVersion(String)
    case missingSHA256(String)
    case invalidSHA256(String)
    case invalidHardware(String)
    case invalidProvisioner(Int, String)
    case guiTestingNotImplemented
    case missingFiles([String])

    public var description: String {
        switch self {
        case .invalidName(let name): "invalid box name \"\(name)\" (expected e.g. \"greg/macos-27\")"
        case .missingVersion: "recipe needs a version"
        case .invalidVersion(let version): "invalid version \"\(version)\" (expected e.g. \"1.0.0\")"
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

    var name: String
    var version: String
    var description: String?
    var cpus: Int?
    var memory: ByteSize?
    var disk: ByteSize?
    var source: RawSource
    var guiTesting: GUITesting?
    var provision: [Provisioner]?

    private enum CodingKeys: String, CodingKey {
        case name, version, description, cpus, memory, disk, source, provision
        case guiTesting = "gui_testing"
    }
}
