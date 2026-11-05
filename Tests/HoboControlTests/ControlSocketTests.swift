import Foundation
import Testing
@testable import HoboControl
import HoboCore
import Synchronization

@Suite struct ControlSocketTests {
    /// Short, since socket paths are capped at 103 bytes and the temp directory is long.
    let socket = URL(filePath: "/tmp/hobo-test-\(UUID().uuidString.prefix(8)).sock")

    /// A connection to the server with no `ControlClient` in the way, to send what it never would.
    func connectedSocket() throws -> Int32 {
        let fd = try ControlSocket.makeSocket()
        var address = try ControlSocket.address(socket.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        return fd
    }

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
            .status(VMRunStatus(state: .running, pid: 7, windowShown: true)),
            .accepted, .error("nope"), .output(.stderr, Data([0, 10, 255])), .exited(-15),
        ]
        for response in responses {
            #expect(try ControlSocket.decode(ControlResponse.self, from: ControlSocket.encode(response).dropLast()) == response)
        }
    }

    @Test func clientAndServerTalk() async throws {
        let server = try ControlServer(path: socket) { request, _ in
            switch request {
            case .status: .status(VMRunStatus(state: .running, pid: 7, ipAddress: "192.168.64.5"))
            case .stop(let force): force ? .accepted : .error("not forced")
            case .view: .accepted
            default: .error("unexpected")
            }
        }
        defer { server.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        #expect(try await ControlClient.send(.status, to: socket) == .status(VMRunStatus(state: .running, pid: 7, ipAddress: "192.168.64.5")))
        #expect(try await ControlClient.send(.stop(force: true), to: socket) == .accepted)
        #expect(try await ControlClient.send(.stop(force: false), to: socket) == .error("not forced"))
        #expect(try await ControlClient.send(.view, to: socket) == .accepted)
    }

    @Test func idleTimeoutFieldsRoundTripAndAreAbsentWithoutOne() throws {
        let timed = ControlResponse.status(VMRunStatus(state: .running, pid: 7, idleTimeoutSeconds: 1800, idleSecondsRemaining: 90))
        #expect(try ControlSocket.decode(ControlResponse.self, from: ControlSocket.encode(timed).dropLast()) == timed)
        let untimed = try ControlSocket.encode(VMRunStatus(state: .running, pid: 7))
        #expect(!String(decoding: untimed, as: UTF8.self).contains("idle"))
    }

    /// A plain look isn't use, or a polling `hobo list` would keep a forgotten VM alive; a `renew`
    /// that held the timer couldn't report the time left.
    @Test func everyRequestButStatusAndRenewHoldsTheIdleTimeout() {
        let copy = GuestCopy(direction: .toGuest, sources: ["/a"], destination: "/tmp/", recursive: false)
        #expect(!ControlRequest.status.holdsIdleTimeout && !ControlRequest.renew.holdsIdleTimeout)
        let requests: [ControlRequest] = [.stop(force: false), .exec(command: ["true"]), .copy(copy), .suspend, .snapshot(tag: "a"), .view]
        for request in requests { #expect(request.holdsIdleTimeout, "\(request)") }
    }

    @Test func renewAndStatusSendTheirOwnRequestsAndReturnTheStatus() async throws {
        let path = URL(filePath: "/tmp/hobo-\(UUID().uuidString.prefix(8)).sock")
        let requests = Mutex<[ControlRequest]>([])
        let server = try ControlServer(path: path) { request, _ in
            requests.withLock { $0.append(request) }
            return .status(VMRunStatus(state: .running, pid: 7))
        }
        defer { server.close() }
        #expect(try await ControlClient.renew(at: path).pid == 7)
        #expect(try await ControlClient.status(at: path).pid == 7)
        #expect(requests.withLock { $0 } == [ControlRequest.renew, .status])
    }

    /// VM processes from before `windowShown` existed leave it out of their status.
    @Test func statusWithoutWindowDecodes() throws {
        let line = Data(#"{"status":{"_0":{"state":"running","pid":7}}}"#.utf8)
        #expect(try ControlSocket.decode(ControlResponse.self, from: line) == .status(VMRunStatus(state: .running, pid: 7)))
    }

    @Test func streamingRequestsRoundTrip() throws {
        let copy = GuestCopy(direction: .toGuest, sources: ["/a b"], destination: "/tmp/", recursive: true)
        for request: ControlRequest in [.exec(command: ["echo", "a\nb"]), .copy(copy), .suspend] {
            let envelope = ControlEnvelope(version: ControlProtocol.version, request: request)
            #expect(try ControlSocket.decode(ControlEnvelope.self, from: ControlSocket.encode(envelope).dropLast()) == envelope)
        }
    }

    @Test func streamsOutputThenTheLastResponse() throws {
        // Several frames in one write, so the client must keep what follows each newline.
        let server = try ControlServer(path: socket) { request, reply in
            guard case .exec(let command, _) = request else { return .error("expected exec") }
            try? reply.send(.output(.stdout, Data(command.joined(separator: " ").utf8)))
            try? reply.send(.output(.stderr, Data("warning\n".utf8)))
            return .exited(3)
        }
        defer { server.close() }
        var received: [(GuestStream, String)] = []
        let last = try ControlClient.stream(.exec(command: ["echo", "hi"]), to: socket) { stream, data in
            received.append((stream, String(decoding: data, as: UTF8.self)))
        }
        #expect(last == .exited(3))
        #expect(received.map(\.0) == [.stdout, .stderr])
        #expect(received.map(\.1) == ["echo hi", "warning\n"])
    }

    @Test func streamReturnsAnErrorResponse() throws {
        let server = try ControlServer(path: socket) { _, _ in .error("not running") }
        defer { server.close() }
        #expect(try ControlClient.stream(.exec(command: ["true"]), to: socket) { _, _ in } == .error("not running"))
    }

    @Test(.timeLimit(.minutes(1))) func clientHangingUpCancelsTheHandler() async throws {
        let (cancelled, signal) = AsyncStream.makeStream(of: Void.self)
        let server = try ControlServer(path: socket) { _, _ in
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                signal.yield()
            }
            return .exited(0)
        }
        defer { server.close() }
        let fd = try connectedSocket()
        try ControlSocket.writeAll(fd, ControlSocket.encode(ControlEnvelope(version: ControlProtocol.version, request: .exec(command: ["sleep", "60"]))))
        try await Task.sleep(for: .milliseconds(200))
        close(fd)
        let start = ContinuousClock.now
        var iterator = cancelled.makeAsyncIterator()
        await iterator.next()
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// The flag goes on the wire as a plain bool, not wrapped.
    @Test func windowShownIsAPlainBool() throws {
        let text = String(decoding: try ControlSocket.encode(VMRunStatus(state: .running, pid: 7, windowShown: true)), as: UTF8.self)
        #expect(text.contains(#""windowShown":true"#))
    }

    @Test func serverRefusesOtherProtocolVersions() throws {
        let server = try ControlServer(path: socket) { _, _ in .accepted }
        defer { server.close() }
        let fd = try connectedSocket()
        defer { close(fd) }
        // A request this version doesn't know must still get the version error, not a decoding one.
        try ControlSocket.writeAll(fd, Data("{\"version\":\(ControlProtocol.version + 1),\"request\":{\"view\":{}}}\n".utf8))
        var reader = LineReader(fd: fd)
        let response = try ControlSocket.decode(ControlResponse.self, from: try #require(try reader.next()))
        guard case .error(let message) = response else { Issue.record("expected an error, got \(response)"); return }
        #expect(message.contains("hobo stop --force"))
    }

    /// `hobo snapshot save` knows a VM process from before snapshots by this answer.
    @Test func serverAnswersARequestItDoesntKnowWithABadMessage() throws {
        let server = try ControlServer(path: socket) { _, _ in .accepted }
        defer { server.close() }
        let fd = try connectedSocket()
        defer { close(fd) }
        try ControlSocket.writeAll(fd, Data("{\"version\":\(ControlProtocol.version),\"request\":{\"fromTheFuture\":{}}}\n".utf8))
        var reader = LineReader(fd: fd)
        let response = try ControlSocket.decode(ControlResponse.self, from: try #require(try reader.next()))
        guard case .error(let message) = response else { Issue.record("expected an error, got \(response)"); return }
        #expect(message.hasPrefix(String(describing: ControlError.badMessage(""))))
    }

    @Test func serverReplacesAStaleSocketFile() async throws {
        try Data().write(to: socket)
        let server = try ControlServer(path: socket) { _, _ in .accepted }
        defer { server.close() }
        #expect(try await ControlClient.send(.status, to: socket) == .accepted)
    }

    @Test func closingRemovesTheSocket() throws {
        let server = try ControlServer(path: socket) { _, _ in .accepted }
        server.close()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        #expect(throws: ControlError.self) { try ControlClient.send(.status, to: socket) as ControlResponse }
    }

    @Test func overlongPathsAreRefused() {
        let path = "/tmp/" + String(repeating: "a", count: ControlSocket.maxPathBytes)
        #expect(throws: ControlError.pathTooLong(path)) { try ControlClient.send(.status, to: URL(filePath: path)) }
        #expect(throws: ControlError.pathTooLong(path)) { try ControlServer(path: URL(filePath: path)) { _, _ in .accepted } }
        #expect(throws: Never.self) { try ControlSocket.checkPath("/tmp/" + String(repeating: "a", count: ControlSocket.maxPathBytes - 5)) }
    }
}
