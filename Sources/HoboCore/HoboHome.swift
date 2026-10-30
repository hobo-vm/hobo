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

    /// Downloaded IPSWs, named by content hash.
    public var depot: URL { root.appending(path: "depot") }
    /// Box build working directories and post-install checkpoints.
    public var roundhouse: URL { root.appending(path: "roundhouse") }
    public var checkpoints: URL { roundhouse.appending(path: "checkpoints") }
    /// Vagrant's insecure private key, written out for `ssh -i`.
    public var insecurePrivateKey: URL { root.appending(path: "insecure_private_key") }

    /// Writes the insecure private key (mode 0600) if it is missing and returns its path.
    public func ensureInsecurePrivateKey() throws -> URL {
        let url = insecurePrivateKey
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Conventions.insecurePrivateKey.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
