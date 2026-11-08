import Foundation
import HoboControl
import HoboCore
import Synchronization
import Virtualization

/// The host's side of hobo-agent (`Agent/`, decision 15): commands and copies over virtio-vsock,
/// with no network, SSH or keys involved. Each request is a connection: a JSON line, then frames
/// (`AgentFrame`) both ways. Closing the connection cancels the request, and the agent kills what
/// it started.
public struct GuestAgent: GuestShell {
    /// Opens a connection to the agent's port; `GuestVM.connectToAgent`.
    let connect: @Sendable () async throws -> AgentSocket
    /// Whom commands run as and copies read and write as.
    var user = Conventions.username

    public static let fetchPort: UInt32 = 1100
    public static let agentPort: UInt32 = 1101
    /// The agent's `protocolVersion`.
    static let protocolVersion = 1

    @discardableResult
    public func run(_ command: String, quiet: Bool) async throws -> Int32 {
        try await stream(command) { stream, data in
            guard !quiet else { return }
            (stream == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(data)
        }
    }

    public func stream(_ command: String, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        try await stream(AgentRequest(op: "exec", command: command, user: user), onOutput: onOutput)
    }

    /// `hobo exec`: runs `command` (an argv) for `platform`'s guest, in its desktop session if `gui`.
    /// Cancelling the task ends the command in the guest too.
    public func exec(
        _ command: [String], gui: Bool, platform: any VMBundle.Type, onOutput: @escaping @Sendable (GuestStream, Data) -> Void
    ) async throws -> Int32 {
        var request = AgentRequest(op: "exec", command: platform.agentCommand(command, gui: gui), user: user)
        if gui && platform.agentStartsInDesktop { request.desktop = true }
        return try await stream(request, onOutput: onOutput)
    }

    private func stream(_ request: AgentRequest, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        try await perform(request) { kind, payload in
            switch kind {
            case .stdout: onOutput(.stdout, payload)
            case .stderr: onOutput(.stderr, payload)
            default: throw AgentError.unexpectedFrame(kind)
            }
        }
    }

    public func copy(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        switch copy.direction {
        case .toGuest: try await put(copy, onOutput: onOutput)
        case .fromGuest: try await get(copy, onOutput: onOutput)
        }
    }

    public func upload(_ local: URL, to remote: String) async throws {
        let copy = GuestCopy(direction: .toGuest, sources: [local.path], destination: remote, recursive: true)
        let status = try await self.copy(copy) { _, data in FileHandle.standardError.write(data) }
        if status != 0 { throw VMError.commandFailed("copying \(local.path) → \(remote)", status) }
    }

    /// Pings the agent until it answers. A guest that is still booting refuses the connection at
    /// once, so this costs nothing while it waits.
    public func waitUntilReachable(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await isReachable() { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw VMError.timedOut("waiting for hobo-agent in the guest")
    }

    /// Whether the agent answers a ping now.
    public func isReachable() async -> Bool {
        (try? await perform(AgentRequest(op: "ping")) { kind, _ in throw AgentError.unexpectedFrame(kind) }) == 0
    }

    // MARK: Copies

    /// Sends the sources as a tar stream, made by the host's `tar`, for the agent to extract as `scp` would.
    private func put(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        var operands: [String] = []
        var failed = false
        for source in copy.sources {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) {
                onOutput(.stderr, Data("\(source): no such file or directory\n".utf8))
                failed = true
            } else if isDirectory.boolValue, !copy.recursive {
                onOutput(.stderr, Data("\(source): is a directory (cp -r copies directories)\n".utf8))
                failed = true
            } else {
                let url = URL(filePath: source).standardizedFileURL
                // `./` keeps a name starting with `-` from reading as an option.
                operands += ["-C", url.deletingLastPathComponent().path, "./" + url.lastPathComponent]
            }
        }
        guard !operands.isEmpty else { return 1 }
        let tar = HostTar(arguments: ["-c", "-f", "-", "--no-xattrs", "--no-mac-metadata"] + operands)
        let request = AgentRequest(op: "put", user: user, destination: copy.destination, single: copy.sources.count == 1)
        let status = try await perform(request, send: { socket in
            try tar.run(reading: { chunk in try socket.writeFrame(.data, chunk) })
            try socket.writeFrame(.data, Data())
        }) { kind, payload in
            guard kind == .stderr else { throw AgentError.unexpectedFrame(kind) }
            onOutput(.stderr, payload)
        }
        if let problem = tar.problem {
            onOutput(.stderr, Data("tar: \(problem)\n".utf8))
            failed = true
        }
        // A copy the agent finished still fails for a source skipped here or tar's own failure.
        return status == 0 && failed ? 1 : status
    }

    /// Receives the sources as a tar stream and extracts it with the host's `tar`, as `scp` would:
    /// into a directory that exists, or a single source as the destination itself.
    private func get(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        let destination = URL(filePath: copy.destination)
        var isDirectory: ObjCBool = false
        let intoDirectory = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if !intoDirectory {
            if copy.destination.hasSuffix("/") {
                onOutput(.stderr, Data("\(copy.destination): no such directory\n".utf8))
                return 1
            }
            if copy.sources.count > 1 {
                onOutput(.stderr, Data("\(copy.destination): not a directory\n".utf8))
                return 1
            }
        }
        // A single source lands in a staging directory beside the destination, then takes its name.
        let staging = destination.deletingLastPathComponent().appending(path: ".hobo-cp-\(UUID().uuidString)")
        let extractInto = intoDirectory ? destination : staging
        if !intoDirectory { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false) }
        defer { if !intoDirectory { try? FileManager.default.removeItem(at: staging) } }

        let tar = HostTar(arguments: ["-x", "-f", "-", "-C", extractInto.path])
        let input = try tar.startWriting()
        let request = AgentRequest(op: "get", user: user, sources: copy.sources, recursive: copy.recursive)
        let status: Int32
        do {
            status = try await perform(request) { kind, payload in
                switch kind {
                case .stderr: onOutput(.stderr, payload)
                case .data where payload.isEmpty: try? input.close()
                case .data: try input.write(contentsOf: payload)
                default: throw AgentError.unexpectedFrame(kind)
                }
            }
        } catch {
            try? input.close()
            tar.finish()
            throw error
        }
        try? input.close()
        tar.finish()
        if let problem = tar.problem {
            onOutput(.stderr, Data("tar: \(problem)\n".utf8))
            return 1
        }
        if !intoDirectory, let entry = try FileManager.default.contentsOfDirectory(atPath: staging.path).first {
            var destinationIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory), !destinationIsDirectory.boolValue {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging.appending(path: entry), to: destination)
        }
        return status
    }

    // MARK: Requests

    /// Opens a connection, sends `request` and, if given, `send`'s stream alongside reading the
    /// answer; passes each output or data frame to `onFrame`, and returns the exit status that ends
    /// it. Cancelling the task closes the connection, which the agent takes as a cancel.
    private func perform(
        _ request: AgentRequest, send: (@Sendable (AgentSocket) throws -> Void)? = nil,
        onFrame: @escaping @Sendable (AgentFrame, Data) throws -> Void
    ) async throws -> Int32 {
        let socket = try await connect()
        defer { socket.close() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                Thread.detachNewThread {
                    continuation.resume(with: Result {
                        try socket.write(try JSONEncoder().encode(request) + Data("\n".utf8))
                        let sender = send.map { BackgroundSend(socket, $0) }
                        let answer = Result { try Self.readAnswer(socket, onFrame: onFrame) }
                        // The sender must be done with the socket before it is closed, or its writes
                        // could land on whatever reuses the descriptor; a failed answer wakes it.
                        if case .failure = answer { socket.shutdown() }
                        let sent = Result { try sender?.wait() }
                        let status = try answer.get()
                        try sent.get()
                        return status
                    })
                }
            }
        } onCancel: {
            socket.shutdown()
        }
    }

    private static func readAnswer(_ socket: AgentSocket, onFrame: (AgentFrame, Data) throws -> Void) throws -> Int32 {
        while true {
            guard let (kind, payload) = try socket.readFrame() else { throw AgentError.disconnected }
            switch kind {
            case .exit:
                guard payload.count == 4 else { throw AgentError.badFrame("an exit status of \(payload.count) bytes") }
                return Int32(bitPattern: payload.reduce(0) { $0 << 8 | UInt32($1) })
            case .error:
                throw AgentError.refused(String(decoding: payload, as: UTF8.self))
            default:
                try onFrame(kind, payload)
            }
        }
    }
}

/// A request's stream to the agent, written on a thread of its own while the answer is read.
private final class BackgroundSend: Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let failure = Mutex<(any Error)?>(nil)

    init(_ socket: AgentSocket, _ send: @escaping @Sendable (AgentSocket) throws -> Void) {
        Thread.detachNewThread { [self] in
            do { try send(socket) } catch { failure.withLock { $0 = error } }
            done.signal()
        }
    }

    func wait() throws {
        done.wait()
        if let error = failure.withLock({ $0 }) { throw error }
    }
}

/// The JSON line that opens a request; the agent's `request`.
struct AgentRequest: Encodable, Equatable {
    var version = GuestAgent.protocolVersion
    var op: String
    var command: String?
    var desktop: Bool?
    var user: String?
    var destination: String?
    var single: Bool?
    var sources: [String]?
    var recursive: Bool?
}

/// The agent's frame types: a type byte, a big-endian UInt32 length, then the payload.
enum AgentFrame: UInt8 {
    case stdout = 0x31 // "1"
    case stderr = 0x32 // "2"
    /// A chunk of a tar stream; an empty one ends it.
    case data = 0x64 // "d"
    /// Ends a request with its exit status, a big-endian Int32.
    case exit = 0x78 // "x"
    /// Ends a request that couldn't run, with the reason.
    case error = 0x72 // "r"

    static let maxPayload = 1 << 20
}

enum AgentError: Error, Equatable, CustomStringConvertible {
    case disconnected
    case refused(String)
    case unexpectedFrame(AgentFrame)
    case badFrame(String)
    case unreachable(String)

    var description: String {
        switch self {
        case .disconnected: "hobo-agent closed the connection before the request finished"
        case .refused(let reason): "hobo-agent: \(reason)"
        case .unexpectedFrame(let frame): "hobo-agent sent an unexpected \(frame) frame"
        case .badFrame(let what): "hobo-agent sent \(what)"
        case .unreachable(let reason): "can't reach hobo-agent in the guest: \(reason)"
        }
    }
}

/// One connection to the agent, or from the stub: a socket VZ handed over, read and written
/// with blocking calls from one thread at a time in each direction.
final class AgentSocket: Sendable {
    let fd: Int32
    private let closed = Atomic(false)

    /// Takes ownership of `fd`.
    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        // A write after the guest has gone fails instead of killing the process.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        if !closed.exchange(true, ordering: .relaxed) { Darwin.close(fd) }
    }

    /// Ends both directions, waking a thread blocked on either.
    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentError.unreachable(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    /// Exactly `count` bytes, or nil at a clean end of file before the first.
    func read(exactly count: Int) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if got < 0 {
                if errno == EINTR { continue }
                throw AgentError.unreachable(String(cString: strerror(errno)))
            }
            if got == 0 {
                if offset == 0 { return nil }
                throw AgentError.disconnected
            }
            offset += got
        }
        return data
    }

    /// Reads up to a newline (not past it), for the stub's fetch line.
    func readLine(limit: Int = 4096) throws -> String? {
        var line = Data()
        while line.count < limit {
            guard let byte = try read(exactly: 1) else { return line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
            if byte[0] == UInt8(ascii: "\n") { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
        return nil
    }

    func writeFrame(_ kind: AgentFrame, _ payload: Data) throws {
        var start = payload.startIndex
        repeat {
            let end = min(start + AgentFrame.maxPayload, payload.endIndex)
            let length = UInt32(end - start)
            var header = Data([kind.rawValue])
            header.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            try write(header + payload[start..<end])
            start = end
        } while start < payload.endIndex
    }

    /// The next frame, or nil at a clean end of file between frames.
    func readFrame() throws -> (AgentFrame, Data)? {
        guard let header = try read(exactly: 5) else { return nil }
        guard let kind = AgentFrame(rawValue: header[0]) else { throw AgentError.badFrame("a frame of unknown type \(header[0])") }
        let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= AgentFrame.maxPayload else { throw AgentError.badFrame("a frame of \(length) bytes") }
        if length == 0 { return (kind, Data()) }
        guard let payload = try read(exactly: length) else { throw AgentError.disconnected }
        return (kind, payload)
    }
}

/// The host's `tar` (bsdtar), making or extracting a copy's stream. AppleDouble files and extended
/// attributes stay out of what goes to the guest; bsdtar refuses `..` and absolute entry names in
/// what comes back.
final class HostTar: Sendable {
    private let process = Mutex(Process())
    private let errors = Mutex(Data())

    init(arguments: [String]) {
        process.withLock { process in
            process.executableURL = URL(filePath: "/usr/bin/tar")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["COPYFILE_DISABLE"] = "1"
            process.environment = environment
        }
    }

    /// What went wrong, from tar's messages or exit status, once it has finished.
    var problem: String? {
        guard let status = process.withLock({ $0.isRunning ? nil : $0.terminationStatus }), status != 0 else { return nil }
        let message = String(decoding: errors.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "exited with status \(status)" : message
    }

    /// Runs tar to completion, passing its stdout to `chunk` as it arrives.
    func run(reading chunk: (Data) throws -> Void) throws {
        let output = Pipe(), errorPipe = Pipe()
        try process.withLock { process in
            process.standardOutput = output
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let collectErrors = collect(errorPipe)
        defer {
            collectErrors.wait()
            process.withLock { $0.waitUntilExit() }
        }
        let handle = output.fileHandleForReading
        while case let data = handle.readData(ofLength: 256 << 10), !data.isEmpty {
            do {
                try chunk(data)
            } catch {
                process.withLock { $0.terminate() }
                throw error
            }
        }
    }

    /// Starts tar reading what is written to the handle returned; `finish` waits for it.
    func startWriting() throws -> FileHandle {
        let input = Pipe(), errorPipe = Pipe()
        try process.withLock { process in
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            try process.run()
        }
        finishing.withLock { $0 = collect(errorPipe) }
        // A tar that has given up makes writes fail rather than kill the process.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return input.fileHandleForWriting
    }

    private let finishing = Mutex<DispatchSemaphore?>(nil)

    func finish() {
        finishing.withLock { $0 }?.wait()
        process.withLock { $0.waitUntilExit() }
    }

    private func collect(_ pipe: Pipe) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            errors.withLock { $0.append(data) }
            done.signal()
        }
        return done
    }
}

// MARK: The stub's fetch

/// Serves the stub's fetch (`Agent/stub.go`): one JSON line naming the guest's platform, answered
/// with the agent built for it. FROZEN, like the stub: every stub ever installed must get its
/// agent this way.
@MainActor
final class AgentFetchServer: NSObject, @MainActor VZVirtioSocketListenerDelegate {
    /// The agents a stub can fetch, by Go's `<GOOS>-<GOARCH>`.
    nonisolated static func binary(for platform: String) -> Data? {
        switch platform {
        case "linux-arm64": HoboAgentBinaries.linux
        case "darwin-arm64": HoboAgentBinaries.darwin
        case "windows-arm64": HoboAgentBinaries.windows
        default: nil
        }
    }

    func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { return false }
        let socket = AgentSocket(fd: fd)
        Thread.detachNewThread { Self.serve(socket) }
        return true
    }

    private struct Fetch: Decodable { var fetch: String }

    private nonisolated static func serve(_ socket: AgentSocket) {
        defer { socket.close() }
        func answer(_ fields: [String: Any]) throws {
            try socket.write(try JSONSerialization.data(withJSONObject: fields) + Data("\n".utf8))
        }
        do {
            guard let line = try socket.readLine(), let fetch = try? JSONDecoder().decode(Fetch.self, from: Data(line.utf8)) else {
                return try answer(["error": "expected a fetch"])
            }
            guard let binary = binary(for: fetch.fetch) else {
                return try answer(["error": "this hobo has no agent for \(fetch.fetch)"])
            }
            try answer(["size": binary.count])
            try socket.write(binary)
        } catch {
            // The stub retries.
        }
    }
}

extension GuestVM {
    /// The VM's virtio-vsock device, which every bundle's configuration has (`agentSocketDevice`).
    var socketDevice: VZVirtioSocketDevice? { machine.socketDevices.first as? VZVirtioSocketDevice }

    /// Answers the stub's fetch from boot on; `init` calls it.
    func serveAgentFetches() {
        guard let socketDevice else { return }
        let listener = VZVirtioSocketListener()
        listener.delegate = agentFetchServer
        socketDevice.setSocketListener(listener, forPort: GuestAgent.fetchPort)
    }

    /// A connection to the agent in the guest. It is refused while the guest boots, until the agent listens.
    func connectToAgent() async throws -> AgentSocket {
        guard let socketDevice else { throw AgentError.unreachable("the VM has no virtio-vsock device") }
        let connection: VZVirtioSocketConnection
        do {
            connection = try await socketDevice.connect(toPort: GuestAgent.agentPort)
        } catch {
            throw AgentError.unreachable(error.localizedDescription)
        }
        defer { connection.close() }
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { throw AgentError.unreachable(String(cString: strerror(errno))) }
        return AgentSocket(fd: fd)
    }

    /// The guest's agent, reached through this VM.
    public var agent: GuestAgent {
        GuestAgent(connect: { @Sendable [weak self] in
            guard let self else { throw AgentError.unreachable("the VM is gone") }
            return try await self.connectToAgent()
        })
    }
}

/// The virtio-vsock device every VM has, for hobo-agent.
func agentSocketDevice() -> VZVirtioSocketDeviceConfiguration { VZVirtioSocketDeviceConfiguration() }
