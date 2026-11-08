import Foundation
import HoboControl
import HoboCore
import Synchronization

/// How the host runs things in a guest: `GuestAgent` over virtio-vsock (decision 15), or
/// `GuestSSH` for the part of a macOS create before the agent is installed. Commands are lines
/// for the `vagrant` user's login shell either way, so the same command strings work over both.
public protocol GuestShell: Sendable {
    /// Runs `command`, streaming its output to the log unless `quiet`, and returns its exit status.
    @discardableResult
    func run(_ command: String, quiet: Bool) async throws -> Int32
    /// Runs `command`, passing its output to `onOutput` as it arrives, and returns its exit status.
    func stream(_ command: String, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32
    /// `hobo cp`; its messages arrive as output. Returns its exit status.
    func copy(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32
    /// Copies a host file or directory to the guest path `remote`, as `scp -r` would.
    func upload(_ local: URL, to remote: String) async throws
    /// Waits until the guest can run commands.
    func waitUntilReachable(timeout: Duration) async throws
}

extension GuestShell {
    @discardableResult
    public func run(_ command: String) async throws -> Int32 { try await run(command, quiet: false) }

    /// Runs `command` and throws if it fails.
    public func check(_ command: String, what: String) async throws {
        let status = try await run(command)
        if status != 0 { throw VMError.commandFailed(what, status) }
    }

    /// Runs `command` and returns its stdout, trimmed; throws if it fails.
    public func output(_ command: String, what: String) async throws -> String {
        let collected = Mutex(Data())
        let status = try await stream(command) { stream, data in
            if stream == .stdout { collected.withLock { $0.append(data) } }
        }
        if status != 0 { throw VMError.commandFailed(what, status) }
        return String(decoding: collected.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes `contents` to a guest file via a host temp file.
    public func upload(contents: String, to remote: String) async throws {
        let local = FileManager.default.temporaryDirectory.appending(path: "hobo-\(UUID().uuidString)")
        try contents.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }
        try await upload(local, to: remote)
    }
}
