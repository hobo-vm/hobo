import Foundation

/// Unix-socket plumbing shared by `ControlServer` and `ControlClient`: one request line, one
/// response line, per connection.
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

    static func setTimeout(_ fd: Int32, _ timeout: Duration) {
        let (seconds, attoseconds) = timeout.components
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
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

    /// Reads up to the first newline (excluded) or end of file.
    static func readLine(_ fd: Int32) throws -> Data {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("read")
            }
            if count == 0 { return line }
            if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                return line + buffer[..<newline]
            }
            line.append(contentsOf: buffer[..<count])
            if line.count > maxMessageBytes { throw ControlError.badMessage("message over \(maxMessageBytes) bytes") }
        }
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

/// Serves a VM process's control socket (mode 0600). Requests are answered by `handler`; a
/// request from a client with another protocol version gets an error instead.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

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

    private static func serve(_ connection: Int32, handler: @escaping Handler) {
        // An accepted socket inherits the listener's O_NONBLOCK; reads here should block.
        _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
        ControlSocket.disableSIGPIPE(connection)
        ControlSocket.setTimeout(connection, .seconds(10))
        Task.detached {
            defer { Darwin.close(connection) }
            let response: ControlResponse
            do {
                let envelope = try ControlSocket.decode(ControlEnvelope.self, from: ControlSocket.readLine(connection))
                if envelope.version == ControlProtocol.version {
                    response = await handler(envelope.request)
                } else {
                    response = .error(
                        "this VM process speaks control protocol \(ControlProtocol.version), not \(envelope.version); "
                            + "restart the VM with the current hobo (hobo stop --force, then hobo start)"
                    )
                }
            } catch {
                response = .error(String(describing: error))
            }
            try? ControlSocket.writeAll(connection, ControlSocket.encode(response))
        }
    }
}

/// Sends one request to a VM process's control socket.
public enum ControlClient {
    public static func send(_ request: ControlRequest, to path: URL, timeout: Duration = .seconds(10)) throws -> ControlResponse {
        var address = try ControlSocket.address(path.path)
        let fd = try ControlSocket.makeSocket()
        defer { close(fd) }
        ControlSocket.setTimeout(fd, timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ControlError.unreachable(path.path, String(cString: strerror(errno))) }
        try ControlSocket.writeAll(fd, ControlSocket.encode(ControlEnvelope(version: ControlProtocol.version, request: request)))
        let line = try ControlSocket.readLine(fd)
        if line.isEmpty { throw ControlError.badMessage("the VM process closed the connection without answering") }
        return try ControlSocket.decode(ControlResponse.self, from: line)
    }
}
