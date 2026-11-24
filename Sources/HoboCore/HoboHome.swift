import Foundation

/// Hobo's global state directory, `~/.hobo` (overridable with `HOBO_HOME`).
public struct HoboHome: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> HoboHome {
        if let override = ProcessInfo.processInfo.environment["HOBO_HOME"], !override.isEmpty {
            return HoboHome(root: URL(filePath: override, directoryHint: .isDirectory))
        }
        return HoboHome(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hobo"))
    }

    /// The image index, `images.json` (see `ImageIndex`).
    public var images: URL { root.appending(path: "images.json") }
    /// Hobo's insecure private key, written out for `ssh -i`.
    public var insecurePrivateKey: URL { root.appending(path: "insecure_private_key") }
    /// The `hobo ui` commands that failed, and what they printed (see `UIFailureLog`).
    public var uiFailures: URL { root.appending(path: "ui-failures.log") }

    /// Writes the insecure private key (mode 0600) unless the file already holds it, and returns its
    /// path. A file holding anything else, such as a key from an older build, is replaced.
    public func ensureInsecurePrivateKey() throws -> URL {
        let url = insecurePrivateKey
        if (try? String(contentsOf: url, encoding: .utf8)) != Conventions.insecurePrivateKey {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Conventions.insecurePrivateKey.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
