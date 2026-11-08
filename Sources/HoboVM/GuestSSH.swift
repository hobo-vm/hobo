import Foundation
import Synchronization
import HoboControl
import HoboCore

/// SSH into a guest with the system `ssh`/`scp`. Password auth goes through `SSH_ASKPASS`, since
/// macOS ships no `sshpass`; it is only used until the insecure key is installed.
public struct GuestSSH: GuestShell {
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

    /// Runs the guest command `line` builds, like `stream`, but cancelling also ends it in the guest:
    /// without a TTY, closing the ssh session doesn't signal it. `line` takes a marker unique to this
    /// run and must print it and a process ID on a line of their own before anything else it runs
    /// (`VMBundle.execLine`). The marker line is kept out of the output and the ID passed to `cancel`
    /// for the command that ends it; anything a startup file printed first passes through.
    public func exec(
        line: @Sendable (String) -> String, cancel: @escaping @Sendable (Int32) -> String,
        onOutput: @escaping @Sendable (GuestStream, Data) -> Void
    ) async throws -> Int32 {
        let pidMarker = PIDMarker(onOutput)
        let status = try await stream(line(pidMarker.marker), onOutput: pidMarker.receive)
        pidMarker.finish()
        if Task.isCancelled, let pid = pidMarker.pid {
            // A task of its own, since this one's cancellation would end the kill's ssh at once.
            _ = try? await Task { try await run(cancel(pid), quiet: true) }.value
        }
        return status
    }

    public func exec(
        _ command: [String], gui: Bool, platform: any VMBundle.Type, onOutput: @escaping @Sendable (GuestStream, Data) -> Void
    ) async throws -> Int32 {
        try await exec(
            line: { gui ? platform.guiExecLine(command, marker: $0) : platform.execLine(command, marker: $0) },
            cancel: { platform.cancelCommand(pid: $0) },
            onOutput: onOutput
        )
    }

    /// Runs `copy` with scp, passing scp's messages to `onOutput`, and returns its exit status.
    /// Cancelling the task ends scp.
    public func copy(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        try await launch("/usr/bin/scp", options() + copy.scpArguments(remote: remote), output: .capture(onOutput))
    }

    /// Copies a host file or directory into the guest.
    public func upload(_ local: URL, to remote: String) async throws {
        let status = try await launch("/usr/bin/scp", ["-r", "-q"] + options() + [local.path, "\(self.remote):\(remote)"], output: .inherit)
        if status != 0 { throw VMError.commandFailed("scp \(local.path) → \(remote)", status) }
    }

    /// Retries a no-op command until sshd accepts us. `exit 0` is one in any guest's shell.
    public func waitUntilReachable(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await run("exit 0", quiet: true) == 0 { return }
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

    /// Runs ssh or scp to completion. Spawned with responsibility disclaimed (`DisclaimedProcess`),
    /// so connecting to the guest network doesn't need hobo's own Local Network permission.
    private func launch(_ executable: String, _ arguments: [String], output: Output) async throws -> Int32 {
        var environment: [String: String]?
        var askpass: URL?
        if case .password(let password) = auth {
            let script = FileManager.default.temporaryDirectory.appending(path: "hobo-askpass-\(UUID().uuidString)")
            try "#!/bin/sh\nprintf '%s\\n' \"$HOBO_SSH_PASSWORD\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = script.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["HOBO_SSH_PASSWORD"] = password
            environment = env
            askpass = script
        }
        defer { if let askpass { try? FileManager.default.removeItem(at: askpass) } }

        var pipes: [(GuestStream, Pipe)] = []
        let stdout: DisclaimedProcess.Stream, stderr: DisclaimedProcess.Stream
        switch output {
        case .inherit:
            (stdout, stderr) = (.inherit, .inherit)
        case .discard:
            (stdout, stderr) = (.null, .null)
        case .capture:
            let outPipe = Pipe(), errPipe = Pipe()
            pipes = [(.stdout, outPipe), (.stderr, errPipe)]
            stdout = .fileDescriptor(outPipe.fileHandleForWriting.fileDescriptor)
            stderr = .fileDescriptor(errPipe.fileHandleForWriting.fileDescriptor)
        }
        let process = try DisclaimedProcess.spawn(executable, arguments, environment: environment, stdout: stdout, stderr: stderr)
        // The child has its own copies; ours would keep the pipes from reaching end of file.
        for (_, pipe) in pipes { try? pipe.fileHandleForWriting.close() }

        return await withTaskCancellationHandler {
            // The exit status is reported once the output has been read to its end, so none is lost.
            async let status = process.waitForExit()
            if case .capture(let onOutput) = output {
                await withTaskGroup(of: Void.self) { group in
                    for (stream, pipe) in pipes {
                        group.addTask {
                            await withCheckedContinuation { continuation in
                                DispatchQueue.global().async {
                                    let handle = pipe.fileHandleForReading
                                    while case let data = handle.availableData, !data.isEmpty { onOutput(stream, data) }
                                    continuation.resume()
                                }
                            }
                        }
                    }
                }
            }
            return await status
        } onCancel: {
            process.terminate()
        }
    }
}

extension GuestSSH.Auth {
    /// How the host logs in to the VM in `bundle` once unattended setup has installed its key.
    /// Every such connection (create's later boots, the VM process, `hobo ssh`) gets its credential
    /// here, so all of them match the guest's `authorized_keys`. Today that is hobo's insecure
    /// key for every VM; a per-VM key (see `TODO.md`) would live in the bundle.
    public static func forVM(bundle: URL, home: HoboHome) throws -> Self {
        .key(try home.ensureInsecurePrivateKey())
    }
}
