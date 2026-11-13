import Foundation

/// A starter recipe: what `hobo init` writes, the template for an OS, pinned to an image when there is one.
public struct RecipeDraft: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// An IPSW from the catalog, or nil for "latest" (unpinned).
        case macOS(IPSWCatalog.Image?)
        case linux(UbuntuCatalog.Image, desktop: Bool)
        /// An installer ISO the user downloaded, with its SHA-256.
        case windows(iso: String, sha256: String)
    }

    public var source: Source

    public init(source: Source) {
        self.source = source
    }

    /// The recipe's TOML.
    public func text() -> String {
        switch source {
        case .macOS(let image?): Recipe.template(pinnedTo: image)
        case .macOS(nil): Recipe.template
        case .linux(let image, let desktop): Recipe.template(pinnedTo: image, desktop: desktop)
        case .windows(let iso, let sha256): Recipe.template(windowsISO: iso, sha256: sha256)
        }
    }
}
