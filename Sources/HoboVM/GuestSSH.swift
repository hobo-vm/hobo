import Foundation
import HoboCore

/// SSH into a guest with the system `ssh`/`scp`. Password auth goes through `SSH_ASKPASS`, since
/// macOS ships no `sshpass`; it is only used until the insecure key is installed.
public struct GuestSSH: Sendable {
    public enum Auth: Sendable {
        case password(String)
        case key(URL)
    }

    public var host: String
    public var user: String
    public var auth: Auth

    public init(host: String, user: String = Conventions.username, auth: Auth) {
        self.host = host
        self.user = user
        self.auth = auth
    }

    /// The command a person can paste to get into the guest.
    public var commandLine: String {
        (["ssh"] + options() + ["\(user)@\(host)"]).map { $0.contains(" ") ? shellQuote($0) : $0 }.joined(separator: " ")
    }

    /// Runs `command` in the guest, streaming its output unless `quiet`. Returns the exit status
    /// (255 means ssh itself failed).
    @discardableResult
    public func run(_ command: String, quiet: Bool = false) async throws -> Int32 {
        try await launch("/usr/bin/ssh", options() + ["\(user)@\(host)", "--", command], quiet: quiet)
    }

    /// Runs `command` and throws if it fails.
    public func check(_ command: String, what: String) async throws {
        let status = try await run(command)
        if status != 0 { throw VMError.commandFailed(what, status) }
    }

    /// Copies a host file or directory into the guest.
    public func upload(_ local: URL, to remote: String) async throws {
        let status = try await launch("/usr/bin/scp", ["-r", "-q"] + options() + [local.path, "\(user)@\(host):\(remote)"], quiet: false)
        if status != 0 { throw VMError.commandFailed("scp \(local.path) → \(remote)", status) }
    }

    /// Writes `contents` to a guest file via a host temp file.
    public func upload(contents: String, to remote: String) async throws {
        let local = FileManager.default.temporaryDirectory.appending(path: "hobo-\(UUID().uuidString)")
        try contents.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }
        try await upload(local, to: remote)
    }

    /// Retries a no-op command until sshd accepts us.
    public func waitUntilReachable(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await run("true", quiet: true) == 0 { return }
            try await Task.sleep(for: .seconds(5))
        }
        throw VMError.timedOut("waiting for SSH on \(host)")
    }

    private func options() -> [String] {
        var options = [
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=15",
        ]
        switch auth {
        case .password:
            options += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
        case .key(let key):
            options += ["-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no", "-i", key.path]
        }
        return options
    }

    private func launch(_ executable: String, _ arguments: [String], quiet: Bool) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if quiet {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        var askpass: URL?
        if case .password(let password) = auth {
            let script = FileManager.default.temporaryDirectory.appending(path: "hobo-askpass-\(UUID().uuidString)")
            try "#!/bin/sh\nprintf '%s\\n' \"$HOBO_SSH_PASSWORD\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = script.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["HOBO_SSH_PASSWORD"] = password
            process.environment = environment
            askpass = script
        }
        defer { if let askpass { try? FileManager.default.removeItem(at: askpass) } }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
