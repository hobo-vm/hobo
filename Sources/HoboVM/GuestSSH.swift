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
        (["ssh"] + sshArguments(command)).map { Self.needsQuoting($0) ? shellQuote($0) : $0 }.joined(separator: " ")
    }

    /// Whether the host's shell would change `argument` if pasted bare: a command can hold `;`,
    /// `$`, quotes, globs or nothing at all, not just spaces.
    static func needsQuoting(_ argument: String) -> Bool {
        argument.isEmpty || !argument.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "@%+=:,./-_".unicodeScalars.contains($0)) }
    }

    /// Runs `command` in the guest, streaming its output unless `quiet`. Returns the exit status
    /// (255 means ssh itself failed).
    @discardableResult
    public func run(_ command: String, quiet: Bool = false) async throws -> Int32 {
        try await launch(Self.sshPath, sshArguments([command]), output: quiet ? .discard : .inherit)
    }

    /// Runs `command` in the guest, passing its output to `onOutput` as it arrives, and returns its
    /// exit status. Cancelling the task ends ssh, and with it the command.
    public func stream(_ command: String, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        try await launch(Self.sshPath, sshArguments([command]), output: .capture(onOutput))
    }

    /// Runs `command` (an argv, quoted for the guest's shell) like `stream`, but cancelling also
    /// ends the command in the guest: without a TTY, closing the ssh session doesn't signal it.
    /// Before exec'ing the command, the guest shell prints its PID (sshd made it a process group
    /// leader) after a marker unique to this run. The marker line is kept out of the output and
    /// the PID used to kill the group on cancel; anything a startup file printed first passes through.
    public func exec(_ command: [String], onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        let pidMarker = PIDMarker(onOutput)
        let status = try await stream(
            "echo \(pidMarker.marker)$$; exec " + command.map(shellQuote).joined(separator: " "), onOutput: pidMarker.receive
        )
        pidMarker.finish()
        if Task.isCancelled, let pid = pidMarker.pid {
            // A task of its own, since this one's cancellation would end the kill's ssh at once.
            _ = try? await Task { try await run("kill -TERM -- -\(pid)", quiet: true) }.value
        }
        return status
    }

    /// Runs `copy` with scp, passing scp's messages to `onOutput`, and returns its exit status.
    /// Cancelling the task ends scp.
    public func copy(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        try await launch("/usr/bin/scp", options() + copy.scpArguments(remote: remote), output: .capture(onOutput))
    }

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

    /// Takes the guest shell's PID from the `<marker><pid>` line in stdout and passes everything
    /// else on, in order.
    final class PIDMarker: Sendable {
        let marker: String
        private let onOutput: @Sendable (GuestStream, Data) -> Void
        /// Stdout not yet passed on while looking for the marker line; nil once it has been found.
        private let state = Mutex<(pending: Data?, pid: Int32?)>((Data(), nil))

        init(token: String = String(UUID().uuidString.prefix(8)).lowercased(), _ onOutput: @escaping @Sendable (GuestStream, Data) -> Void) {
            marker = "hobo-pid-\(token):"
            self.onOutput = onOutput
        }

        var pid: Int32? { state.withLock { $0.pid } }

        func receive(_ stream: GuestStream, _ data: Data) {
            guard stream == .stdout else { return onOutput(stream, data) }
            let ready: Data = state.withLock { state in
                guard var pending = state.pending else { return data }
                pending.append(data)
                let markerBytes = Data(marker.utf8)
                guard let found = pending.firstRange(of: markerBytes) else {
                    // Hold back a tail that could be the start of a marker split across chunks.
                    let keep = min(pending.count, markerBytes.count - 1)
                    state.pending = Data(pending.suffix(keep))
                    return Data(pending.dropLast(keep))
                }
                guard let newline = pending[found.upperBound...].firstIndex(of: UInt8(ascii: "\n")) else {
                    state.pending = Data(pending[found.lowerBound...])
                    return Data(pending[..<found.lowerBound])
                }
                state.pid = Int32(String(decoding: pending[found.upperBound..<newline], as: UTF8.self))
                state.pending = nil
                return Data(pending[..<found.lowerBound]) + pending[pending.index(after: newline)...]
            }
            if !ready.isEmpty { onOutput(stream, ready) }
        }

        /// Passes on anything still held back, once the command's output has ended.
        func finish() {
            let rest = state.withLock { state in
                defer { state.pending = nil }
                return state.pending ?? Data()
            }
            if !rest.isEmpty { onOutput(.stdout, rest) }
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
        // Held until the exit status is in: a Process freed while its child runs never calls its
        // termination handler, and nothing else here is guaranteed to keep it alive.
        defer { withExtendedLifetime(process) {} }
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

extension GuestSSH.Auth {
    /// How the host logs in to the VM in `bundle` once unattended setup has installed its key.
    /// Every such connection (create's later boots, the VM process, `hobo ssh`) gets its credential
    /// here, so all of them match the guest's `authorized_keys`. Today that is Vagrant's insecure
    /// key for every VM; a per-VM key (see `TODO.md`) would live in the bundle.
    public static func forVM(bundle: URL, home: HoboHome) throws -> Self {
        .key(try home.ensureInsecurePrivateKey())
    }
}
