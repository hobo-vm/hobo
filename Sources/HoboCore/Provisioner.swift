import Foundation

/// A `[[provision]]` step, shared by the Boxcar and recipes. What makes a step valid, which host
/// file it reads and the guest command it runs all live here, so every consumer agrees on what a
/// step means.
public struct Provisioner: Equatable, Sendable, Decodable {
    public enum Kind: String, Sendable, Decodable { case shell, file }
    public enum Run: String, Sendable, Decodable { case once, always, never }

    public var type: Kind
    public var inline: String?
    public var path: String?
    public var source: String?
    public var destination: String?
    public var privileged: Bool?
    public var run: Run?
    public var env: [String: String]?

    public init(
        type: Kind, inline: String? = nil, path: String? = nil, source: String? = nil, destination: String? = nil,
        privileged: Bool? = nil, run: Run? = nil, env: [String: String]? = nil
    ) {
        self.type = type
        self.inline = inline
        self.path = path
        self.source = source
        self.destination = destination
        self.privileged = privileged
        self.run = run
        self.env = env
    }

    /// Why the step can't run, or nil when it is well formed.
    public var problem: String? {
        // `env` reads a key with `=` or a leading `-` as something other than the variable intended.
        if let bad = env?.keys.sorted().first(where: { !Self.isVariableName($0) }) {
            return "env key \"\(bad)\" is not a variable name"
        }
        // An empty path resolves to the recipe's directory, which `missingFiles` would accept.
        if [path, source, destination].contains("") { return "path, source and destination can't be empty" }
        return switch type {
        case .shell where (inline == nil) == (path == nil): "shell needs exactly one of inline or path"
        case .file where source == nil || destination == nil: "file needs source and destination"
        default: nil
        }
    }

    private static func isVariableName(_ key: String) -> Bool {
        key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil
    }

    /// The host file the step reads (a shell step's `path` or a file step's `source`), as written.
    public var hostFile: String? { type == .shell ? path : source }

    /// The guest command that runs a shell step's script once it is uploaded to `script`: a login
    /// bash under `sudo -n -H` unless `privileged = false`, with `env` set.
    public func shellCommand(running script: String) -> String {
        let assignments = (env ?? [:]).sorted { $0.key < $1.key }.map { shellQuote("\($0.key)=\($0.value)") }
        let sudo = (privileged ?? true) ? ["sudo", "-n", "-H"] : []
        return (sudo + ["env"] + assignments + ["/bin/bash", "-l", shellQuote(script)]).joined(separator: " ")
    }
}

/// Resolves a host path written in a Boxcar or recipe against the directory of that file.
public func resolveHostPath(_ path: String, relativeTo directory: URL) -> URL {
    URL(filePath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
}
