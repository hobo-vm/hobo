import Foundation
import Synchronization

/// Unix-socket plumbing shared by `ControlServer` and `ControlClient`: one request line, then one
/// response line or a stream of them, per connection.
public enum ControlSocket {
    /// `sockaddr_un.sun_path` holds 104 bytes, including the terminating NUL.
    public static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    /// Longest message either side accepts; anything bigger is a confused peer.
    static let maxMessageBytes = 1 << 20

    /// Throws rather than truncating a path that doesn't fit, which would bind or reach the wrong socket.
    public static func checkPath(_ path: String) throws {
        if path.utf8.count > maxPathBytes { throw ControlError.pathTooLong(path) }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        try checkPath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        disableSIGPIPE(fd)
        return fd
    }

    /// A peer that hangs up mid-write must not kill the process with SIGPIPE.
    static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A zero timeout waits forever.
    static func setTimeout(_ fd: Int32, _ timeout: Duration, options: [Int32] = [SO_RCVTIMEO, SO_SNDTIMEO]) {
        let (seconds, attoseconds) = timeout.components
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        for option in options {
            setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func encode(_ value: some Encodable) throws -> Data {
        // Compact JSON escapes newlines inside strings, so the message is exactly one line.
        try JSONEncoder().encode(value) + Data("\n".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: line)
        } catch {
            throw ControlError.badMessage(String(describing: error))
        }
    }

    /// Reads up to the first newline (excluded) or end of file, for a single-message reply.
    static func readLine(_ fd: Int32) throws -> Data {
        var reader = LineReader(fd: fd)
        return try reader.next() ?? Data()
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write")
                }
                offset += count
            }
        }
    }

    static func posixError(_ call: String) -> Error {
        ControlError.system("\(call): \(String(cString: strerror(errno)))")
    }
}

/// Reads newline-terminated messages from a socket, keeping what follows a newline for the next one.
struct LineReader {
    let fd: Int32
    private var buffer = Data()
    private var atEnd = false

    init(fd: Int32) { self.fd = fd }

    /// The next line without its newline; at end of file, what is left (nil if nothing is).
    mutating func next() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            if atEnd {
                defer { buffer = Data() }
                return buffer.isEmpty ? nil : buffer
            }
            if buffer.count > ControlSocket.maxMessageBytes {
                throw ControlError.badMessage("message over \(ControlSocket.maxMessageBytes) bytes")
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ControlSocket.posixError("read")
            }
            if count == 0 { atEnd = true } else { buffer.append(contentsOf: chunk[..<count]) }
        }
    }
}

/// Sends a streaming request's intermediate responses (`output`) to its client. Safe to call from
/// several threads, e.g. one per output pipe.
public final class ControlReply: Sendable {
    private let fd: Mutex<Int32>

    init(fd: Int32) { self.fd = Mutex(fd) }

    /// Throws if the client is gone.
    public func send(_ response: ControlResponse) throws {
        let data = try ControlSocket.encode(response)
        try fd.withLock { try ControlSocket.writeAll($0, data) }
    }
}

/// Serves a VM process's control socket (mode 0600). Requests are answered by `handler`, which
/// may stream intermediate responses through its `ControlReply` and returns the last one; a
/// request from a client with another protocol version gets an error instead. A client that
/// hangs up cancels its handler's task, which is how a ^C on `hobo exec` stops the guest command.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (ControlRequest, ControlReply) async -> ControlResponse

    private let fd: Int32
    private let path: String
    private let source: any DispatchSourceRead

    public init(path: URL, handler: @escaping Handler) throws {
        self.path = path.path
        var address = try ControlSocket.address(self.path)
        // A socket file left by a process that died; whoever runs the VM owns the path.
        unlink(self.path)
        let fd = try ControlSocket.makeSocket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        func failed(_ call: String) -> Error {
            let error = ControlSocket.posixError("\(call) \(path.path)")
            Darwin.close(fd)
            return error
        }
        guard bound == 0 else { throw failed("bind") }
        guard chmod(path.path, 0o600) == 0 else { throw failed("chmod") }
        guard listen(fd, 16) == 0 else { throw failed("listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "hobo.control.accept"))
        source.setEventHandler {
            while true {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                Self.serve(connection, handler: handler)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    /// Stops listening and removes the socket file.
    public func close() {
        source.cancel()
        unlink(path)
    }

    private struct VersionOnly: Decodable { var version: Int }

    private static func serve(_ connection: Int32, handler: @escaping Handler) {
        // An accepted socket inherits the listener's O_NONBLOCK; reads here should block.
        _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
        ControlSocket.disableSIGPIPE(connection)
        ControlSocket.setTimeout(connection, .seconds(10))
        // Blocking reads and writes run on GCD threads; only the handler uses Swift concurrency's
        // small thread pool, which blocking clients in the same process could otherwise exhaust.
        DispatchQueue.global().async {
            defer { Darwin.close(connection) }
            var reader = LineReader(fd: connection)
            let line: Data
            do {
                line = try reader.next() ?? Data()
            } catch {
                try? ControlSocket.writeAll(connection, ControlSocket.encode(ControlResponse.error(String(describing: error))))
                return
            }
            // A client slow to read a stream (piped into a pager, say) must hold the guest command
            // back, not time out a write: that drops output or leaves half a line on the wire. A
            // client that is gone still fails the write at once.
            ControlSocket.setTimeout(connection, .zero, options: [SO_SNDTIMEO])
            let response = Mutex<ControlResponse?>(nil)
            let handled = DispatchSemaphore(value: 0)
            let handling = Task {
                let result = await respond(to: line, handler: handler, reply: ControlReply(fd: connection))
                response.withLock { $0 = result }
                handled.signal()
            }
            let hangup = watchForHangup(connection) { handling.cancel() }
            handled.wait()
            if let response = response.withLock({ $0 }) {
                try? ControlSocket.writeAll(connection, ControlSocket.encode(response))
            }
            // Wakes the hangup watcher; the descriptor is closed only once it is done reading it.
            shutdown(connection, SHUT_RDWR)
            hangup.wait()
        }
    }

    private static func respond(to line: Data, handler: Handler, reply: ControlReply) async -> ControlResponse {
        do {
            // The version alone first: another version's request may not decode as one of ours.
            let version = try ControlSocket.decode(VersionOnly.self, from: line).version
            guard version == ControlProtocol.version else {
                return .error(
                    "this VM process speaks control protocol \(ControlProtocol.version), not \(version); "
                        + "restart the VM with the current hobo (hobo stop --force, then hobo start)"
                )
            }
            return await handler(try ControlSocket.decode(ControlEnvelope.self, from: line).request, reply)
        } catch {
            return .error(String(describing: error))
        }
    }

    /// Calls `hungUp` when the client closes its end. Clients send nothing after the request, so
    /// any read that ends the stream means it is gone; anything else it sends is ignored. It reads
    /// on a GCD thread, not a Swift concurrency one, since it blocks for as long as the request runs.
    private static func watchForHangup(_ connection: Int32, hungUp: @escaping @Sendable () -> Void) -> DispatchGroup {
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = read(connection, &buffer, buffer.count)
                if count > 0 { continue }
                // The connection's receive timeout ends idle reads; keep waiting.
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                hungUp()
                return
            }
        }
        return done
    }
}

/// Sends one request to a VM process's control socket.
public enum ControlClient {
    public static func send(_ request: ControlRequest, to path: URL, timeout: Duration = .seconds(10)) throws -> ControlResponse {
        let fd = try connect(to: path, timeout: timeout)
        defer { close(fd) }
        try ControlSocket.writeAll(fd, ControlSocket.encode(ControlEnvelope(version: ControlProtocol.version, request: request)))
        var reader = LineReader(fd: fd)
        return try nextResponse(&reader)
    }

    /// `send` for async callers: the blocking socket I/O runs on a GCD thread, so it never ties up
    /// Swift concurrency's small thread pool, which a VM process in the same process needs.
    public static func send(_ request: ControlRequest, to path: URL, timeout: Duration = .seconds(10)) async throws -> ControlResponse {
        try await offPool { try send(request, to: path, timeout: timeout) }
    }

    /// `status(at:)` for async callers, off Swift concurrency's thread pool.
    public static func status(at path: URL) async throws -> VMRunStatus {
        try await offPool { try status(at: path) }
    }

    private static func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result(catching: body)) }
        }
    }

    /// Asks the VM process how it is doing.
    public static func status(at path: URL) throws -> VMRunStatus {
        let response = try send(.status, to: path)
        switch response {
        case .status(let status): return status
        case .error(let message): throw ControlError.badMessage(message)
        default: throw ControlError.badMessage("expected a status, got \(response)")
        }
    }

    /// Sends a streaming request (`exec`, `copy`), passes each `output` response to `onOutput`, and
    /// returns the last response. It waits as long as the request runs; closing the connection
    /// (e.g. the client exiting on ^C) cancels it in the VM process.
    public static func stream(
        _ request: ControlRequest, to path: URL, onOutput: (GuestStream, Data) throws -> Void
    ) throws -> ControlResponse {
        let fd = try connect(to: path, timeout: .seconds(10))
        defer { close(fd) }
        try ControlSocket.writeAll(fd, ControlSocket.encode(ControlEnvelope(version: ControlProtocol.version, request: request)))
        // A guest command can stay quiet for as long as it likes.
        ControlSocket.setTimeout(fd, .zero, options: [SO_RCVTIMEO])
        var reader = LineReader(fd: fd)
        while true {
            let response = try nextResponse(&reader)
            guard case .output(let stream, let data) = response else { return response }
            try onOutput(stream, data)
        }
    }

    private static func connect(to path: URL, timeout: Duration) throws -> Int32 {
        var address = try ControlSocket.address(path.path)
        let fd = try ControlSocket.makeSocket()
        ControlSocket.setTimeout(fd, timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ControlError.unreachable(path.path, reason)
        }
        return fd
    }

    private static func nextResponse(_ reader: inout LineReader) throws -> ControlResponse {
        guard let line = try reader.next(), !line.isEmpty else {
            throw ControlError.badMessage("the VM process closed the connection without answering")
        }
        return try ControlSocket.decode(ControlResponse.self, from: line)
    }
}
