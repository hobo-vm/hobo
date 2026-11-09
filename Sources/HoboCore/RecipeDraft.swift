import Foundation

/// A starter recipe: what `hobo init` writes, and what Hobo.app's New VM sheet writes to a temporary
/// directory to create from. The machine settings and `[gui_testing]` override the template's.
public struct RecipeDraft: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// An IPSW from the catalog, or nil for "latest" (unpinned).
        case macOS(IPSWCatalog.Image?)
        case linux(UbuntuCatalog.Image, desktop: Bool)
        /// An installer ISO the user downloaded, with its SHA-256.
        case windows(iso: String, sha256: String)
    }

    public var source: Source
    /// Nil keeps the template's default for the OS.
    public var cpus: Int?
    public var memory: ByteSize?
    public var disk: ByteSize?
    /// Turns on `[gui_testing]`, which only macOS guests have.
    public var guiTesting: Bool

    public init(source: Source, cpus: Int? = nil, memory: ByteSize? = nil, disk: ByteSize? = nil, guiTesting: Bool = false) {
        self.source = source
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.guiTesting = guiTesting
    }

    public var os: VMConfig.OS {
        switch source {
        case .macOS: .macOS
        case .linux: .linux
        case .windows: .windows
        }
    }

    /// The recipe's TOML.
    public func text() throws -> String {
        if guiTesting && os != .macOS { throw RecipeError.macOSOnly("[gui_testing]") }
        var text = switch source {
        case .macOS(let image?): Recipe.template(pinnedTo: image)
        case .macOS(nil): Recipe.template
        case .linux(let image, let desktop): Recipe.template(pinnedTo: image, desktop: desktop)
        case .windows(let iso, let sha256): Recipe.template(windowsISO: iso, sha256: sha256)
        }
        if let cpus { text = Self.replacingSetting("cpus  ", with: String(cpus), in: text) }
        if let memory { text = Self.replacingSetting("memory", with: "\"\(memory)\"", in: text) }
        if let disk { text = Self.replacingSetting("disk  ", with: "\"\(disk)\"", in: text) }
        if guiTesting {
            text += """

                [gui_testing]
                enabled = true

                """
        }
        return text
    }

    /// The template's line `<key> = <value>`, which each template has once at the top, given a new value.
    private static func replacingSetting(_ key: String, with value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix("\(key) = ") }) else {
            preconditionFailure("every recipe template sets \(key)")
        }
        lines[index] = "\(key) = \(value)"
        return lines.joined(separator: "\n")
    }
}
