import Foundation
import HoboCore

/// The app menu's Install Command Line Tool: a symlink `/usr/local/bin/hobo` to the app's
/// `Contents/Helpers/hobo`, on every Mac's default PATH. Writing there needs an administrator, so it
/// goes through `osascript … with administrator privileges` rather than a privileged helper.
public struct CommandLineTool: Sendable {
    public var link: URL
    public var target: URL

    public static let standardLink = URL(filePath: "/usr/local/bin/hobo")

    public init(link: URL = Self.standardLink, target: URL = HoboInstall.cli) {
        self.link = link
        self.target = target
    }

    public enum State: Equatable, Sendable {
        case installed
        case missing
        /// Something else is there: another build's link, or a copied binary.
        case other(String)
    }

    public var state: State {
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(filePath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            return resolved.path == target.standardizedFileURL.path ? .installed : .other(resolved.path)
        }
        return manager.fileExists(atPath: link.path) ? .other(link.path) : .missing
    }

    /// The shell command that makes the link, replacing whatever is there.
    public var command: String {
        "/bin/mkdir -p \(shellQuote(link.deletingLastPathComponent().path)) && /bin/ln -sfn \(shellQuote(target.path)) \(shellQuote(link.path))"
    }

    /// Makes the link, asking for an administrator's password. Throws if it is refused or fails.
    public func install() throws {
        let script = "do shell script \(Self.appleScriptString(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandLineToolError(description: message.isEmpty ? "couldn't link \(link.path)" : message)
        }
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public struct CommandLineToolError: Error, CustomStringConvertible {
    public var description: String
}
