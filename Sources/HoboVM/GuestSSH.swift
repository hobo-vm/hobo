import Foundation
import Synchronization
import HoboControl
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

    public static let sshPath = "/usr/bin/ssh"

    /// ssh's arguments (without argv[0]) to log in, or with `command`, to run it as ssh would.
    public func sshArguments(_ command: [String] = []) -> [String] {
        options() + [remote] + (command.isEmpty ? [] : ["--"] + command)
    }

    /// The command a person can paste to get into the guest (or run `command` there).
    public func commandLine(_ command: [String] = []) -> String {
        (["ssh"] + sshArguments(command)).map { $0.contains(" ") ? shellQuote($0) : $0 }.joined(separator: " ")
    }

    /// Runs `command` in the guest, streaming its output unless `quiet`. Returns the exit status
    /// (255 means ssh itself failed).
    @discardableResult
    public func run(_ command: String, quiet: Bool = false) async throws -> Int32 {
        try await launch(Self.sshPath, options() + [remote, "--", command], output: quiet ? .discard : .inherit)
    }

    /// Runs `command` in the guest, passing its output to `onOutput` as it arrives, and returns its
    /// exit status. Cancelling the task ends ssh, and with it the command.
    public func stream(_ command: String, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        try await launch(Self.sshPath, options() + [remote, "--", command], output: .capture(onOutput))
    }

    /// Runs `command` (an argv, quoted for the guest's shell) like `stream`, but cancelling also
    /// ends the command in the guest: without a TTY, closing the ssh session doesn't signal it.
    /// The guest shell prints its PID, which sshd made a process group leader, before exec'ing the
    /// command; that first line is kept out of the output and used to kill the group on cancel.
    public func exec(_ command: [String], onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        let leader = LeaderLine(onOutput)
        let status = try await stream("echo $$; exec " + command.map(shellQuote).joined(separator: " "), onOutput: leader.receive)
        if Task.isCancelled, let pid = leader.pid {
            // A task of its own, since this one's cancellation would end the kill's ssh at once.
            _ = try? await Task { try await run("kill -TERM -- -\(pid)", quiet: true) }.value
        }
        return status
    }

    /// Runs `copy` with scp, passing scp's messages to `onOutput`, and returns its exit status.
    /// Cancelling the task ends scp.
    public func copy(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        let arguments = options() + copy.scpArguments(remote: remote)
        return try await launch("/usr/bin/scp", arguments, output: .capture(onOutput))
    }

    /// Runs `command` and throws if it fails.
    public func check(_ command: String, what: String) async throws {
        let status = try await run(command)
        if status != 0 { throw VMError.commandFailed(what, status) }
    }

    /// Copies a host file or directory into the guest.
    public func upload(_ local: URL, to remote: String) async throws {
        let status = try await launch("/usr/bin/scp", ["-r", "-q"] + options() + [local.path, "\(self.remote):\(remote)"], output: .inherit)
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

    private var remote: String { "\(user)@\(host)" }

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

    /// Takes the guest shell's PID from the first line of stdout and passes the rest on.
    final class LeaderLine: Sendable {
        private let onOutput: @Sendable (GuestStream, Data) -> Void
        /// The first line so far, until its newline arrives; then nil.
        private let state = Mutex<(firstLine: Data?, pid: Int32?)>((Data(), nil))

        init(_ onOutput: @escaping @Sendable (GuestStream, Data) -> Void) { self.onOutput = onOutput }

        var pid: Int32? { state.withLock { $0.pid } }

        func receive(_ stream: GuestStream, _ data: Data) {
            guard stream == .stdout else { return onOutput(stream, data) }
            let rest: Data? = state.withLock { state in
                guard let earlier = state.firstLine else { return data }
                guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
                    state.firstLine = earlier + data
                    return nil
                }
                state.firstLine = nil
                state.pid = Int32(String(decoding: earlier + data[..<newline], as: UTF8.self))
                // Not a PID (a guest startup file printed first, say): it's the command's output.
                if state.pid == nil { return earlier + data }
                return data[data.index(after: newline)...]
            }
            if let rest, !rest.isEmpty { onOutput(stream, Data(rest)) }
        }
    }

    private enum Output {
        case inherit
        case discard
        case capture(@Sendable (GuestStream, Data) -> Void)
    }

    private func launch(_ executable: String, _ arguments: [String], output: Output) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var pipes: [(GuestStream, Pipe)] = []
        switch output {
        case .inherit:
            break
        case .discard:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .capture:
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            pipes = [(.stdout, stdout), (.stderr, stderr)]
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
        // The exit status is reported once the output has been read to its end, so none is lost.
        let drained = DispatchGroup()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    drained.notify(queue: .global()) { continuation.resume(returning: process.terminationStatus) }
                }
                // Entered before launch: a command that exits at once must still wait for its output.
                for _ in pipes { drained.enter() }
                do {
                    try process.run()
                } catch {
                    for _ in pipes { drained.leave() }
                    continuation.resume(throwing: error)
                    return
                }
                if case .capture(let onOutput) = output {
                    for (stream, pipe) in pipes {
                        // The child has its own copy; ours would keep the pipe from reaching end of file.
                        try? pipe.fileHandleForWriting.close()
                        DispatchQueue.global().async {
                            let handle = pipe.fileHandleForReading
                            while case let data = handle.availableData, !data.isEmpty { onOutput(stream, data) }
                            drained.leave()
                        }
                    }
                }
                if Task.isCancelled { process.terminate() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
