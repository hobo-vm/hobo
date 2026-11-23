import CryptoKit
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
    static let protocolVersion = 2

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
    /// With `tool`, the agent fetches that tool from the host first, if it hasn't this boot or
    /// what it has isn't what this hobo serves (`Agent/tool.go`), for the command to run.
    public func exec(
        _ command: [String], gui: Bool, platform: any VMBundle.Type, tool: String? = nil,
        onOutput: @escaping @Sendable (GuestStream, Data) -> Void
    ) async throws -> Int32 {
        try await stream(execRequest(command, gui: gui, platform: platform, tool: tool), onOutput: onOutput)
    }

    /// Starts `command` as `exec` does and keeps the connection, for a conversation in lines over its
    /// stdin and stdout (`AgentSession`): the hobo ui backends' (designs/hobo-ui-linux-windows.md).
    public func session(_ command: [String], gui: Bool, platform: any VMBundle.Type, tool: String? = nil) async throws -> AgentSession {
        var request = try execRequest(command, gui: gui, platform: platform, tool: tool)
        request.stdin = true
        let socket = try await connect()
        do {
            try socket.write(try JSONEncoder().encode(request) + Data("\n".utf8))
        } catch {
            socket.close()
            throw error
        }
        return AgentSession(socket)
    }

    private func execRequest(_ command: [String], gui: Bool, platform: any VMBundle.Type, tool: String?) throws -> AgentRequest {
        var request = AgentRequest(op: "exec", command: platform.agentCommand(command, gui: gui), user: user)
        request.tool = tool
        request.toolDigest = try tool.flatMap { try AgentFetchServer.digest($0, goos: platform.goos) }
        if gui && platform.agentStartsInDesktop { request.desktop = true }
        return request
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

    /// `hobo rm`: the agent removes the paths as the guest user, reporting each it can't.
    public func remove(_ remove: GuestRemove, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        try await stream(AgentRequest(op: "rm", user: user, sources: remove.paths, force: remove.force), onOutput: onOutput)
    }

    public func upload(_ local: URL, to remote: String) async throws {
        let copy = GuestCopy(direction: .toGuest, sources: [local.path], destination: remote)
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

    // MARK: Clipboard

    /// The shared clipboard's request (`ClipboardSync`): the agent runs its helper in the desktop
    /// session, which sets the guest's clipboard to each text from `outgoing` and passes each new
    /// text the guest copies to `onText`, on a thread of the request's own. It lasts until the task
    /// is cancelled, which ends the helper, or the helper ends; it returns the helper's status:
    /// `GUISession.unavailableStatus` if the guest's desktop session never came up.
    public func clipboard(outgoing: AsyncStream<String>, onText: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let socket = try await connect()
        defer { socket.close() }
        try socket.write(try JSONEncoder().encode(AgentRequest(op: "clipboard", user: user)) + Data("\n".utf8))
        let sender = Task.detached {
            for await text in outgoing {
                try socket.writeFrame(.text, Data(text.utf8))
                try socket.writeFrame(.text, Data())
            }
        }
        let answer: Result<Int32, any Error>
        do {
            answer = .success(try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    Thread.detachNewThread {
                        let text = ClipboardTextReader(onText: onText)
                        continuation.resume(with: Result { try Self.readAnswer(socket, onFrame: text.receive) })
                    }
                }
            } onCancel: {
                socket.shutdown()
            })
        } catch {
            answer = .failure(error)
        }
        // The sender must be done with the socket before it is closed; shutting it down wakes a
        // blocked write, and cancelling ends the wait for the next text.
        socket.shutdown()
        sender.cancel()
        _ = await sender.result
        return try answer.get()
    }

    // MARK: Copies

    /// Sends the sources as a tar stream, made by the host's `tar`, for the agent to extract as `scp` would.
    private func put(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
        var operands: [String] = []
        var failed = false
        for source in copy.sources {
            if !FileManager.default.fileExists(atPath: source) {
                onOutput(.stderr, Data("\(source): no such file or directory\n".utf8))
                failed = true
            } else if URL(filePath: source).standardizedFileURL.path == "/" {
                // It has no name to copy it under, and holds /dev, whose files never end.
                onOutput(.stderr, Data("\(source): is the filesystem root (copy a directory in it)\n".utf8))
                failed = true
            } else {
                let url = URL(filePath: source).standardizedFileURL
                // `./` keeps a name starting with `-` from reading as an option.
                operands += ["-C", url.deletingLastPathComponent().path, "./" + url.lastPathComponent]
            }
        }
        guard !operands.isEmpty else { return 1 }
        let tar = HostTar(arguments: ["-c", "-f", "-", "--no-xattrs", "--no-mac-metadata"] + operands)
        let request = AgentRequest(op: "put", user: user, destination: copy.destination, single: copy.sources.count == 1, replace: copy.replace)
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
    /// into a directory that exists, or a single source as the destination itself, which it also is
    /// when the destination is a directory of the source's own name. The directories above a
    /// destination that isn't there are made, as the agent's `putTar` makes them in the guest, and
    /// removed again by a copy that brings nothing. With `replace`, what a source lands on in that
    /// directory is removed first, once the whole copy has arrived.
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
        // A single source onto a directory of its own name is that directory, as the agent's
        // putTar takes it, unless the destination ends in a slash. Its name is the one it arrives
        // under, so where tar extracts waits for the stream's first entry.
        let mayBeOntoItsOwnName = intoDirectory && copy.sources.count == 1 && !copy.destination.hasSuffix("/")
        let extraction = GetExtraction(destination: destination, intoDirectory: intoDirectory, replace: copy.replace)
        defer { extraction.cleanUp() }
        if !mayBeOntoItsOwnName { try extraction.start(sourceName: nil) }
        let request = AgentRequest(op: "get", user: user, sources: copy.sources)
        let status: Int32
        do {
            status = try await perform(request) { kind, payload in
                switch kind {
                case .stderr: onOutput(.stderr, payload)
                case .data: try extraction.receive(payload)
                default: throw AgentError.unexpectedFrame(kind)
                }
            }
        } catch {
            extraction.abandon()
            throw error
        }
        try extraction.finish()
        if let problem = extraction.problem {
            onOutput(.stderr, Data("tar: \(problem)\n".utf8))
            return 1
        }
        try extraction.land()
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

/// A command in the guest spoken to in lines: each `send` writes one line to its stdin and
/// returns the next line it prints. Blocking, for one thread at a time; `close` ends its input
/// and waits for it to exit. What it prints to stderr is kept for the error when it ends early.
public final class AgentSession: @unchecked Sendable {
    private let socket: AgentSocket
    private var pending = Data()
    private var errors = Data()
    private var exited: Int32?

    init(_ socket: AgentSocket) { self.socket = socket }

    deinit { socket.close() }

    public func send(_ line: Data) throws -> Data {
        try socket.writeFrame(.stdin, line + Data("\n".utf8))
        return try readLine()
    }

    /// The next line of stdout, without its newline.
    func readLine() throws -> Data {
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                return Data(line)
            }
            guard exited == nil, try receive() else { throw ended() }
        }
    }

    /// Takes in the next frame; false at the end of the connection.
    private func receive() throws -> Bool {
        guard let (kind, payload) = try socket.readFrame() else { return false }
        switch kind {
        case .stdout: pending.append(payload)
        case .stderr: errors.append(payload)
        case .exit: exited = payload.count == 4 ? Int32(bitPattern: payload.reduce(0) { $0 << 8 | UInt32($1) }) : -1
        case .error: throw AgentError.refused(String(decoding: payload, as: UTF8.self))
        default: throw AgentError.unexpectedFrame(kind)
        }
        return true
    }

    private func ended() -> Error {
        let said = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = exited.map { "exited with status \($0)" } ?? "closed the connection"
        return AgentError.refused("the command \(status)\(said.isEmpty ? "" : ": \(said)")")
    }

    /// Ends its input and waits for it to exit, giving its status.
    @discardableResult
    public func close() throws -> Int32 {
        defer { socket.close() }
        if exited == nil { try socket.writeFrame(.stdin, Data()) }
        while exited == nil {
            guard try receive() else { throw AgentError.disconnected }
        }
        return exited ?? -1
    }

    /// Ends it without waiting: the agent takes a closed connection as a cancel.
    public func cancel() { socket.shutdown() }
}

/// Puts a clipboard text back together from its text frames, up to the empty one that ends it.
/// A text over `ClipboardSync.maxText` is dropped.
private final class ClipboardTextReader: @unchecked Sendable {
    // Only ever used from the one thread reading the request's answer.
    private var text = Data()
    private var over = false
    private let onText: @Sendable (String) -> Void

    init(onText: @escaping @Sendable (String) -> Void) { self.onText = onText }

    func receive(_ kind: AgentFrame, _ payload: Data) throws {
        guard kind == .text else { throw AgentError.unexpectedFrame(kind) }
        if !payload.isEmpty {
            if text.count + payload.count > ClipboardSync.maxText { over = true; text = Data() }
            if !over { text += payload }
            return
        }
        if !over, !text.isEmpty { onText(String(decoding: text, as: UTF8.self)) }
        text = Data()
        over = false
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
    var tool: String?
    var toolDigest: String?
    var stdin: Bool?
    var user: String?
    var destination: String?
    var single: Bool?
    var replace: Bool?
    var sources: [String]?
    var force: Bool?
}

/// The agent's frame types: a type byte, a big-endian UInt32 length, then the payload.
enum AgentFrame: UInt8 {
    /// A chunk of an exec's input, to the guest; an empty one closes it.
    case stdin = 0x30 // "0"
    case stdout = 0x31 // "1"
    case stderr = 0x32 // "2"
    /// A chunk of a tar stream; an empty one ends it.
    case data = 0x64 // "d"
    /// A chunk of clipboard text (UTF-8, LF line endings), either way; an empty one ends the text.
    case text = 0x74 // "t"
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
            let length = UInt32(end - start).bigEndian
            try write(Data([kind.rawValue]) + withUnsafeBytes(of: length) { Data($0) } + payload[start..<end])
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
    /// Signalled once `startWriting`'s tar has closed its stderr; `finish` waits for it.
    private let finishing = Mutex<DispatchSemaphore?>(nil)
    /// Signalled when tar exits. `get` launches tar, awaits the copy, then waits for tar on
    /// whatever thread it resumed on, and `waitUntilExit` on a thread other than the launching one
    /// can miss the exit and block in its run loop for good. So the exit is awaited through this.
    private let exited = DispatchSemaphore(value: 0)

    init(arguments: [String]) {
        process.withLock { process in
            process.executableURL = URL(filePath: "/usr/bin/tar")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["COPYFILE_DISABLE"] = "1"
            process.environment = environment
            process.terminationHandler = { [exited] _ in exited.signal() }
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
            exited.wait()
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

    /// Waits for `startWriting`'s tar to exit. Call it once.
    func finish() {
        guard let finishing = finishing.withLock({ $0 }) else { return }
        finishing.wait()
        exited.wait()
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

/// Extracts a copy out of the guest (`GuestAgent.get`) with the host's `tar`, then moves what it
/// extracted into place. Where tar extracts can depend on the name the single source arrives under,
/// its first entry's, so the stream is held until that entry's header is in.
/// Used by one thread at a time: the one reading the answer, then the copy's.
private final class GetExtraction: @unchecked Sendable {
    /// The most of the stream held for the first entry's name; past it, the name decides nothing.
    static let headerLimit = 1 << 20

    private var destination: URL
    private let intoDirectory: Bool
    private let replace: Bool
    /// What arrived before tar started, while it waits on the first entry's name.
    private var held = Data()
    private var staging: URL?
    /// The directories this copy made above the destination, deepest first.
    private var made: [URL] = []
    private var tar: HostTar?
    private var input: FileHandle?

    init(destination: URL, intoDirectory: Bool, replace: Bool) {
        self.destination = destination
        self.intoDirectory = intoDirectory
        self.replace = replace
    }

    /// Makes where tar extracts and starts it. When `sourceName` (the top-level name of the stream's
    /// first entry) is the destination directory's own name, tar extracts into its parent, so the
    /// source lands on that directory.
    func start(sourceName: String?) throws {
        if sourceName == destination.lastPathComponent { destination.deleteLastPathComponent() }
        // A single source lands in a staging directory beside the destination, then takes its name.
        // Sources that replace what's in a directory are staged inside it, then moved into place.
        let staged = !intoDirectory || replace
        let stagingParent = intoDirectory ? destination : destination.deletingLastPathComponent()
        let staging = stagingParent.appending(path: ".hobo-cp-\(UUID().uuidString)")
        var missing = stagingParent
        while !FileManager.default.fileExists(atPath: missing.path) {
            made.append(missing)
            missing = missing.deletingLastPathComponent()
        }
        if staged {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            self.staging = staging
        }
        let tar = HostTar(arguments: ["-x", "-f", "-", "-C", (staged ? staging : destination).path])
        input = try tar.startWriting()
        self.tar = tar
    }

    /// A data frame's payload: the stream, or its end when empty.
    func receive(_ payload: Data) throws {
        let endOfStream = payload.isEmpty
        if tar == nil {
            held += payload
            let first = TarStream.firstEntryName(held)
            if first == .incomplete, !endOfStream, held.count < Self.headerLimit { return }
            try start(sourceName: Self.topLevelName(of: first))
            if !held.isEmpty { try input?.write(contentsOf: held) }
            held = Data()
        } else if !endOfStream {
            try input?.write(contentsOf: payload)
        }
        if endOfStream { try? input?.close() }
    }

    /// The first component of an entry's name other than `.`, which is the source's own name.
    private static func topLevelName(of entry: TarStream.FirstEntry) -> String? {
        guard case .name(let name) = entry else { return nil }
        return name.split(separator: "/").first { $0 != "." }.map(String.init)
    }

    /// Ends the stream, starting tar on what was held if it hadn't started, and waits for tar.
    func finish() throws {
        if tar == nil { try receive(Data()) }
        try? input?.close()
        tar?.finish()
    }

    /// Ends tar on a copy that failed.
    func abandon() {
        try? input?.close()
        tar?.finish()
    }

    /// What went wrong in tar, once it has finished.
    var problem: String? { tar?.problem }

    /// Moves what tar extracted into place.
    func land() throws {
        guard let staging else { return }
        if !intoDirectory {
            if let entry = try FileManager.default.contentsOfDirectory(atPath: staging.path).first {
                var destinationIsDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory), !destinationIsDirectory.boolValue {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: staging.appending(path: entry), to: destination)
            }
        } else {
            for entry in try FileManager.default.contentsOfDirectory(atPath: staging.path) {
                let target = destination.appending(path: entry)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: staging.appending(path: entry), to: target)
            }
        }
    }

    func cleanUp() {
        if let staging { try? FileManager.default.removeItem(at: staging) }
        // rmdir leaves one that holds something, which is every one of them once the copy has landed.
        for directory in made where rmdir(directory.path) != 0 { break }
    }
}

/// Reading a tar stream's headers as the stream arrives.
enum TarStream {
    enum FirstEntry: Equatable {
        /// More of the stream is needed to tell.
        case incomplete
        /// The first entry's name, as the archive gives it.
        case name(String)
        /// The stream holds no entry, or isn't one tar can name.
        case none
    }

    /// The name of the first entry in `stream`'s start: a PAX `path` record or a GNU long name ahead
    /// of its header if there is one, otherwise the header's own name, after a ustar prefix.
    static func firstEntryName(_ stream: Data) -> FirstEntry {
        let bytes = [UInt8](stream)
        var offset = 0
        var longName: String?
        while true {
            guard bytes.count >= offset + 512 else { return .incomplete }
            let header = Array(bytes[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) { return .none }
            guard let size = number(header[124..<136]), size >= 0 else { return .none }
            let typeflag = header[156]
            let data = offset + 512
            switch typeflag {
            case UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"), UInt8(ascii: "K"):
                guard bytes.count - data >= size else { return .incomplete }
                let content = bytes[data..<data + size]
                if typeflag == UInt8(ascii: "x"), let path = paxPath(content) { longName = path }
                if typeflag == UInt8(ascii: "L") { longName = string(content) }
                offset = data + (size + 511) / 512 * 512
            default:
                if let longName { return .name(longName) }
                let name = string(header[0..<100])
                let magic = Array(header[257..<263])
                let prefix = magic == Array("ustar\0".utf8) ? string(header[345..<500]) : ""
                return .name(prefix.isEmpty ? name : prefix + "/" + name)
            }
        }
    }

    /// A NUL-terminated field.
    private static func string(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// A numeric field: octal digits, or base-256 when its first byte's high bit is set.
    private static func number(_ field: ArraySlice<UInt8>) -> Int? {
        if let first = field.first, first & 0x80 != 0 {
            return field.dropFirst().reduce(Int(first & 0x7f)) { $0 << 8 | Int($1) }
        }
        let digits = field.drop { $0 == 0x20 }.prefix { $0 != 0 && $0 != 0x20 }
        return digits.isEmpty ? 0 : Int(String(decoding: digits, as: UTF8.self), radix: 8)
    }

    /// The `path` record of a PAX header's records, each `<length> <key>=<value>\n`.
    private static func paxPath(_ records: ArraySlice<UInt8>) -> String? {
        var rest = records
        var path: String?
        while let space = rest.firstIndex(of: 0x20),
            let length = Int(String(decoding: rest[rest.startIndex..<space], as: UTF8.self)),
            length > space - rest.startIndex + 1, rest.count >= length {
            let record = rest[(space + 1)..<(rest.startIndex + length)].dropLast()  // the newline
            if let equals = record.firstIndex(of: UInt8(ascii: "=")),
                String(decoding: record[record.startIndex..<equals], as: UTF8.self) == "path" {
                path = String(decoding: record[(equals + 1)...], as: UTF8.self)
            }
            rest = rest.dropFirst(length)
        }
        return path
    }
}

// MARK: The stub's fetch

/// Serves the stub's fetch (`Agent/stub.go`): one JSON line naming the guest's platform, answered
/// with the agent built for it. FROZEN, like the stub: every stub ever installed must get its
/// agent this way. The agent fetches its tools (`Agent/tool.go`) the same way, by names of the
/// form `<tool>-<GOOS>-<GOARCH>`, which no stub sends.
@MainActor
final class AgentFetchServer: NSObject, @MainActor VZVirtioSocketListenerDelegate {
    /// The agents a stub can fetch, by Go's `<GOOS>-<GOARCH>`, and the tools an agent can: nil for
    /// a platform there is none for, and a throw if this build is missing the file.
    nonisolated static func binary(for platform: String) throws -> Data? {
        switch platform {
        case "linux-arm64": try Payloads.agent("linux")
        case "darwin-arm64": try Payloads.agent("darwin")
        case "windows-arm64": try Payloads.agent("windows")
        case "ui-darwin-arm64": try Payloads.hoboUI()
        case "ui-linux-arm64": try Payloads.uiBackend("linux")
        case "ui-windows-arm64": try Payloads.uiBackend("windows")
        default: nil
        }
    }

    /// The SHA-256 (hex) of the tool an agent in a `goos` guest would fetch now, which it compares
    /// with the one it has: hobo may have been updated since it fetched it.
    nonisolated static func digest(_ tool: String, goos: String) throws -> String? {
        try binary(for: "\(tool)-\(goos)-arm64").map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
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
            let binary: Data?
            do {
                binary = try Self.binary(for: fetch.fetch)
            } catch {
                return try answer(["error": "\(error)"])
            }
            guard let binary else {
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
