import Foundation
import Testing
@testable import HoboControl

@Suite struct ControlSocketTests {
    /// Short, since socket paths are capped at 103 bytes and the temp directory is long.
    let socket = URL(filePath: "/tmp/hobo-test-\(UUID().uuidString.prefix(8)).sock")

    @Test func requestsAreOneJSONLineWithTheVersion() throws {
        let data = try ControlSocket.encode(ControlEnvelope(version: ControlProtocol.version, request: .stop(force: true)))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n") && text.dropLast().allSatisfy { $0 != "\n" })
        #expect(try ControlSocket.decode(ControlEnvelope.self, from: data.dropLast())
            == ControlEnvelope(version: ControlProtocol.version, request: .stop(force: true)))
    }

    @Test func responsesRoundTrip() throws {
        let responses: [ControlResponse] = [
            .status(VMRunStatus(state: .stopping, pid: 7, detail: "line one\nline two", ipAddress: "192.168.64.5")),
            .accepted, .error("nope"),
        ]
        for response in responses {
            #expect(try ControlSocket.decode(ControlResponse.self, from: ControlSocket.encode(response).dropLast()) == response)
        }
    }

    @Test func clientAndServerTalk() async throws {
        let server = try ControlServer(path: socket) { request in
            switch request {
            case .status: .status(VMRunStatus(state: .running, pid: 7, ipAddress: "192.168.64.5"))
            case .stop(let force): force ? .accepted : .error("not forced")
            }
        }
        defer { server.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        #expect(try ControlClient.send(.status, to: socket) == .status(VMRunStatus(state: .running, pid: 7, ipAddress: "192.168.64.5")))
        #expect(try ControlClient.send(.stop(force: true), to: socket) == .accepted)
        #expect(try ControlClient.send(.stop(force: false), to: socket) == .error("not forced"))
    }

    @Test func serverRefusesOtherProtocolVersions() throws {
        let server = try ControlServer(path: socket) { _ in .accepted }
        defer { server.close() }
        let fd = try ControlSocket.makeSocket()
        defer { close(fd) }
        var address = try ControlSocket.address(socket.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        try ControlSocket.writeAll(fd, ControlSocket.encode(ControlEnvelope(version: ControlProtocol.version + 1, request: .status)))
        let response = try ControlSocket.decode(ControlResponse.self, from: ControlSocket.readLine(fd))
        guard case .error(let message) = response else { Issue.record("expected an error, got \(response)"); return }
        #expect(message.contains("hobo stop --force"))
    }

    @Test func serverReplacesAStaleSocketFile() throws {
        try Data().write(to: socket)
        let server = try ControlServer(path: socket) { _ in .accepted }
        defer { server.close() }
        #expect(try ControlClient.send(.status, to: socket) == .accepted)
    }

    @Test func closingRemovesTheSocket() throws {
        let server = try ControlServer(path: socket) { _ in .accepted }
        server.close()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        #expect(throws: ControlError.self) { try ControlClient.send(.status, to: socket) }
    }

    @Test func overlongPathsAreRefused() {
        let path = "/tmp/" + String(repeating: "a", count: ControlSocket.maxPathBytes)
        #expect(throws: ControlError.pathTooLong(path)) { try ControlClient.send(.status, to: URL(filePath: path)) }
        #expect(throws: ControlError.pathTooLong(path)) { try ControlServer(path: URL(filePath: path)) { _ in .accepted } }
        #expect(throws: Never.self) { try ControlSocket.checkPath("/tmp/" + String(repeating: "a", count: ControlSocket.maxPathBytes - 5)) }
    }
}

@Suite struct VMLifecycleTests {
    @Test func tailKeepsTheLastLines() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "hobo-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: log) }
        try (1...30).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        let tail = VMLifecycle.tail(of: log, lines: 3)
        #expect(tail == "line 28\nline 29\nline 30")
        #expect(VMLifecycle.tail(of: log.appending(path: "missing")).isEmpty)
    }
}
