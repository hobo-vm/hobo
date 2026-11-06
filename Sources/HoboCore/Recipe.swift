import Foundation
import TOMLKit

/// A VM recipe, conventionally `Hobo.toml`: the source, default hardware and `[[provision]]` steps
/// to build a VM from. It holds no host-specific state, so it can be handed to someone else.
/// `[source] ipsw` builds a macOS guest, `[source] image` a Linux one (a cloud image), and
/// `[source] iso` a Windows one (an installer ISO).
public struct Recipe: Equatable, Sendable {
    /// The file `hobo init` writes and `hobo validate` reads by default.
    public static let fileName = "Hobo.toml"
    public static let defaultCPUs = 4

    /// Memory when the recipe gives none: enough for macOS or Windows, or for a Linux desktop.
    public static func defaultMemory(for os: VMConfig.OS) -> ByteSize {
        ByteSize(bytes: os == .linux ? 4 << 30 : 8 << 30)
    }

    /// Disk when the recipe gives none. macOS updates can fail under about 50 GB, and Windows 11's
    /// own minimum is 64 GB.
    public static func defaultDisk(for os: VMConfig.OS) -> ByteSize {
        switch os {
        case .macOS: ByteSize(bytes: 80 << 30)
        case .linux: ByteSize(bytes: 32 << 30)
        case .windows: ByteSize(bytes: 64 << 30)
        }
    }

    /// `.macOS` for `[source] ipsw`, `.linux` for `[source] image`, `.windows` for `[source] iso`.
    public var os: VMConfig.OS
    public var cpus: Int
    public var memory: ByteSize
    public var disk: ByteSize
    public var source: Source
    public var provisioners: [Provisioner]
    /// `[gui_testing]` when enabled: TCC pre-grants so agents can drive the guest UI over SSH.
    public var guiTesting: GUITesting?
    /// `[security]`: SIP and AMFI, on unless the recipe turns them off.
    public var security: Security
    /// The recipe's directory; relative `path`/`source` values resolve against it.
    public var directory: URL

    /// Where the install image (an IPSW, a Linux cloud image, or a Windows ISO) comes from.
    public enum Source: Equatable, Sendable {
        /// The newest IPSW this host supports. Unpinned, so builds warn. macOS only.
        case latest
        case remote(URL, sha256: String)
        case local(URL, sha256: String)

        public var isPinned: Bool { self != .latest }
    }

    /// Turning SIP off needs a person: `create` boots recoveryOS and waits for `csrutil disable`.
    /// AMFI off is the `amfi_get_out_of_my_way=1` boot-arg, set over SSH once SIP is off, so ad-hoc
    /// signed binaries may claim restricted entitlements.
    public struct Security: Equatable, Sendable {
        public var sip = true
        public var amfi = true

        public init(sip: Bool = true, amfi: Bool = true) {
            self.sip = sip
            self.amfi = amfi
        }
    }

    public struct GUITesting: Equatable, Sendable {
        /// Clients granted on top of `GUITestingGrants.defaultClients`: absolute paths or bundle IDs.
        public var allow: [String]
    }

    public static func parse(_ toml: String, directory: URL) throws -> Recipe {
        let raw = try TOMLDecoder().decode(RawRecipe.self, from: toml)
        let (os, source) = try source(from: raw.source, directory: directory)
        if os != .macOS {
            // Both are TCC, SIP and AMFI: macOS mechanisms with no counterpart here. On Windows a
            // desktop-session process can drive other apps with no grant at all.
            if raw.security != nil { throw RecipeError.macOSOnly("[security]") }
            if raw.guiTesting != nil { throw RecipeError.macOSOnly("[gui_testing]") }
        }
        let recipe = Recipe(
            os: os,
            cpus: raw.cpus ?? defaultCPUs,
            memory: raw.memory ?? defaultMemory(for: os),
            disk: raw.disk ?? defaultDisk(for: os),
            source: source,
            provisioners: raw.provision ?? [],
            guiTesting: raw.guiTesting?.enabled == true ? GUITesting(allow: raw.guiTesting?.allow ?? []) : nil,
            security: Security(sip: raw.security?.sip ?? true, amfi: raw.security?.amfi ?? true),
            directory: directory
        )
        // Caught here rather than by diskutil or VZ after the IPSW download.
        if recipe.cpus < 1 { throw RecipeError.invalidHardware("cpus must be at least 1") }
        if recipe.memory.bytes == 0 { throw RecipeError.invalidHardware("memory must be more than 0") }
        if recipe.disk.bytes == 0 { throw RecipeError.invalidHardware("disk must be more than 0") }
        for (index, step) in recipe.provisioners.enumerated() {
            if let problem = step.problem { throw RecipeError.invalidProvisioner(index, problem) }
            // Over SSH, vagrant is an elevated administrator with no way to run as anything less.
            if os == .windows, step.privileged == false {
                throw RecipeError.invalidProvisioner(index, "privileged = false isn't available on Windows, where steps run as vagrant, an administrator")
            }
        }
        if !recipe.security.amfi && recipe.security.sip { throw RecipeError.amfiNeedsSIPOff }
        for client in recipe.guiTesting?.allow ?? [] {
            if client.isEmpty || client.contains(where: \.isWhitespace) || (client.contains("/") && !client.hasPrefix("/")) {
                throw RecipeError.invalidGUITestingClient(client)
            }
        }
        return recipe
    }

    public static func load(from url: URL) throws -> Recipe {
        if !FileManager.default.fileExists(atPath: url.path) { throw RecipeError.notFound(url.relativePath) }
        return try parse(String(contentsOf: url, encoding: .utf8), directory: url.deletingLastPathComponent())
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

    private static func source(from raw: RawRecipe.RawSource, directory: URL) throws -> (VMConfig.OS, Source) {
        let (os, location): (VMConfig.OS, String) = switch (raw.ipsw, raw.image, raw.iso) {
        case (let ipsw?, nil, nil): (.macOS, ipsw)
        case (nil, let image?, nil): (.linux, image)
        case (nil, nil, let iso?): (.windows, iso)
        default: throw RecipeError.sourceKind
        }
        // Only Apple's API resolves a "latest"; there is none for Linux images.
        if os == .macOS && location == "latest" { return (os, .latest) }
        guard let sha = raw.sha256?.lowercased() else { throw RecipeError.missingSHA256(location) }
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw RecipeError.invalidSHA256(sha) }
        if let url = URL(string: location), url.scheme == "https" || url.scheme == "http" {
            return (os, .remote(url, sha256: sha))
        }
        return (os, .local(resolveHostPath(location, relativeTo: directory), sha256: sha))
    }
}

public enum RecipeError: Error, Equatable, CustomStringConvertible {
    /// The path as given, so the message echoes what the user typed.
    case notFound(String)
    case invalidSize(String)
    case sourceKind
    case macOSOnly(String)
    case missingSHA256(String)
    case invalidSHA256(String)
    case invalidHardware(String)
    case invalidProvisioner(Int, String)
    case invalidGUITestingClient(String)
    case amfiNeedsSIPOff
    case missingFiles([String])

    public var description: String {
        switch self {
        case .notFound(let path):
            "no recipe at \(path)" + (path == Recipe.fileName ? " (run hobo init, or pass a recipe path)" : "")
        case .invalidSize(let value): "invalid size \"\(value)\" (expected e.g. \"512MB\" or \"8GB\")"
        case .sourceKind: "[source] needs exactly one of ipsw (a macOS guest), image (a Linux cloud image) or iso (a Windows installer)"
        case .macOSOnly(let table): "\(table) is for macOS guests only; this recipe's [source] isn't an IPSW"
        case .missingSHA256(let source): "source \"\(source)\" needs a sha256 (only ipsw = \"latest\" may omit it)"
        case .invalidSHA256(let sha): "invalid sha256 \"\(sha)\" (expected 64 hex digits)"
        case .invalidHardware(let reason): reason
        case .invalidProvisioner(let index, let reason): "provision step \(index + 1): \(reason)"
        case .amfiNeedsSIPOff: "[security] amfi = false needs sip = false too"
        case .invalidGUITestingClient(let client):
            "[gui_testing] allow entry \"\(client)\": expected an absolute path or a bundle ID"
        case .missingFiles(let paths): "recipe refers to missing files: \(paths.joined(separator: ", "))"
        }
    }
}

private struct RawRecipe: Decodable {
    struct RawSource: Decodable {
        var ipsw: String?
        var image: String?
        var iso: String?
        var sha256: String?
    }

    struct GUITesting: Decodable {
        var enabled: Bool?
        var allow: [String]?
    }

    struct Security: Decodable {
        var sip: Bool?
        var amfi: Bool?
    }

    var cpus: Int?
    var memory: ByteSize?
    var disk: ByteSize?
    var source: RawSource
    var guiTesting: GUITesting?
    var security: Security?
    var provision: [Provisioner]?

    private enum CodingKeys: String, CodingKey {
        case cpus, memory, disk, source, provision, security
        case guiTesting = "gui_testing"
    }
}
