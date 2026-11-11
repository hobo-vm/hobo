import Foundation
import HoboControl
import HoboCore
import Synchronization
import Testing
@testable import HoboVM

/// The host's side of hobo-agent, against a stand-in agent on the other end of a socket pair: the
/// request line, the frames both ways, and the host's half of a copy. Needs no VM.
@Suite struct GuestAgentTests {
    /// A `GuestAgent` whose every connection is answered by `agent`, run on a thread of its own with
    /// the request's JSON line and the agent's end of the connection.
    func guestAgent(_ agent: @escaping @Sendable ([String: Any], AgentSocket) throws -> Void) -> GuestAgent {
        GuestAgent(connect: {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw AgentError.unreachable("socketpair") }
            let theirs = AgentSocket(fd: fds[1])
            Thread.detachNewThread {
                defer { theirs.close() }
                guard let line = try? theirs.readLine(),
                    let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                else { return }
                try? agent(request, theirs)
            }
            return AgentSocket(fd: fds[0])
        })
    }

    func sendExit(_ status: Int32, on socket: AgentSocket) throws {
        try socket.writeFrame(.exit, withUnsafeBytes(of: status.bigEndian) { Data($0) })
    }

    /// Everything the host sends in data frames, up to the empty one that ends it.
    func receiveData(_ socket: AgentSocket) throws -> Data {
        var data = Data()
        while let (kind, payload) = try socket.readFrame(), kind == .data, !payload.isEmpty { data += payload }
        return data
    }

    final class Output: Sendable {
        let collected = Mutex<[GuestStream: Data]>([:])
        func append(_ stream: GuestStream, _ data: Data) { collected.withLock { $0[stream, default: Data()] += data } }
        func text(_ stream: GuestStream) -> String { String(decoding: collected.withLock { $0[stream] ?? Data() }, as: UTF8.self) }
    }

    /// The request line the stand-in agent was sent, its values as text.
    final class Seen: Sendable {
        private let request = Mutex<[String: String]>([:])
        func record(_ fields: [String: Any]) { request.withLock { $0 = fields.mapValues { "\($0)" } } }
        var fields: [String: String] { request.withLock { $0 } }
        func field(_ name: String) -> String? { fields[name] }
    }

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hobo-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func tar(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = arguments
        process.environment = ["COPYFILE_DISABLE": "1"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    // MARK: Requests

    @Test func execSendsTheRequestAndRoutesEachStream() async throws {
        let seen = Seen()
        let agent = guestAgent { request, socket in
            seen.record(request)
            try socket.writeFrame(.stdout, Data("out".utf8))
            try socket.writeFrame(.stderr, Data("err".utf8))
            try sendExit(-3, on: socket)
        }
        let output = Output()
        let status = try await agent.stream("echo hi", onOutput: output.append)
        // A negative status is an Int32's bits, not a large UInt32.
        #expect(status == -3)
        #expect(output.text(.stdout) == "out")
        #expect(output.text(.stderr) == "err")
        #expect(seen.fields == ["version": "1", "op": "exec", "command": "echo hi", "user": Conventions.username])
    }

    // `hobo ui` names its tool, which the agent fetches (Agent/tool.go) by `ui-<GOOS>-<GOARCH>`.
    @Test func execNamesTheToolItNeedsAndTheHostServesIt() async throws {
        let seen = Seen()
        let agent = guestAgent { request, socket in
            seen.record(request)
            try sendExit(0, on: socket)
        }
        _ = try await agent.exec(["true"], gui: true, platform: MacVMBundle.self, tool: "ui") { _, _ in }
        #expect(seen.fields["tool"] == "ui")
        #expect(seen.fields["desktop"] == nil)
        #expect(try AgentFetchServer.binary(for: "ui-darwin-arm64")?.isEmpty == false)
        #expect(try AgentFetchServer.binary(for: "ui-linux-arm64") == nil)
    }

    @Test func anErrorFrameIsARefusal() async throws {
        let agent = guestAgent { _, socket in try socket.writeFrame(.error, Data("unknown request".utf8)) }
        await #expect(throws: AgentError.refused("unknown request")) {
            try await agent.stream("true") { _, _ in }
        }
    }

    @Test func aHangUpBeforeTheExitFrameIsADisconnect() async throws {
        let agent = guestAgent { _, socket in try socket.writeFrame(.stdout, Data("partial".utf8)) }
        await #expect(throws: AgentError.disconnected) {
            try await agent.stream("true") { _, _ in }
        }
    }

    @Test func aDataFrameForACommandIsUnexpected() async throws {
        let agent = guestAgent { _, socket in
            try socket.writeFrame(.data, Data("x".utf8))
            try sendExit(0, on: socket)
        }
        await #expect(throws: AgentError.unexpectedFrame(.data)) {
            try await agent.stream("true") { _, _ in }
        }
    }

    @Test func reachableOnlyWhenThePingSucceeds() async {
        #expect(await guestAgent { _, socket in try sendExit(0, on: socket) }.isReachable())
        #expect(await !guestAgent { _, socket in try sendExit(1, on: socket) }.isReachable())
        #expect(await !GuestAgent(connect: { throw AgentError.unreachable("booting") }).isReachable())
    }

    /// A frame longer than the agent's limit goes as several, which read back as the whole.
    @Test func aLongPayloadIsSplitIntoFramesTheAgentAccepts() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let writer = AgentSocket(fd: fds[0]), reader = AgentSocket(fd: fds[1])
        let payload = Data((0..<(AgentFrame.maxPayload + 10)).map { UInt8(truncatingIfNeeded: $0) })
        Thread.detachNewThread {
            try? writer.writeFrame(.stdout, payload)
            writer.close()
        }
        var lengths: [Int] = []
        var received = Data()
        while let (kind, chunk) = try reader.readFrame() {
            #expect(kind == .stdout)
            lengths.append(chunk.count)
            received += chunk
        }
        #expect(lengths == [AgentFrame.maxPayload, 10])
        #expect(received == payload)
    }

    // MARK: Copies

    @Test func putSendsEachSourceUnderItsOwnName() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "tree/sub"), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: dir.appending(path: "tree/sub/b.txt"))
        try Data("one".utf8).write(to: dir.appending(path: "one.txt"))
        let archive = dir.appending(path: "sent.tar")
        let seen = Seen()
        let agent = guestAgent { request, socket in
            seen.record(request)
            try receiveData(socket).write(to: archive)
            try sendExit(0, on: socket)
        }
        let copy = GuestCopy(direction: .toGuest, sources: [dir.appending(path: "tree").path, dir.appending(path: "one.txt").path], destination: "dest")
        #expect(try await agent.copy(copy) { _, _ in } == 0)
        #expect(seen.field("op") == "put")
        #expect(seen.field("destination") == "dest")
        #expect(seen.field("single") == "0")
        #expect(seen.field("replace") == "0")
        let names = String(decoding: try tar(["-t", "-f", archive.path]), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(Set(names).isSuperset(of: ["./tree/sub/b.txt", "./one.txt"]))
    }

    /// As scp does, a source it can't send is reported and fails the copy, though the rest went.
    @Test func putFailsForASkippedSourceEvenWhenTheAgentSucceeds() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("f".utf8).write(to: dir.appending(path: "file"))
        let agent = guestAgent { _, socket in
            _ = try receiveData(socket)
            try sendExit(0, on: socket)
        }
        let output = Output()
        let missing = dir.appending(path: "missing").path
        let copy = GuestCopy(direction: .toGuest, sources: [missing, dir.appending(path: "file").path], destination: "d")
        #expect(try await agent.copy(copy, onOutput: output.append) == 1)
        #expect(output.text(.stderr).contains("\(missing): no such file or directory"))
    }

    @Test func putRefusesTheFilesystemRoot() async throws {
        let agent = GuestAgent(connect: { Issue.record("connected"); throw AgentError.unreachable("") })
        let output = Output()
        let copy = GuestCopy(direction: .toGuest, sources: ["/"], destination: "d")
        #expect(try await agent.copy(copy, onOutput: output.append) == 1)
        #expect(output.text(.stderr).contains("/: is the filesystem root"))
    }

    @Test func putWithNothingToSendNeverConnects() async throws {
        let agent = GuestAgent(connect: { Issue.record("connected"); throw AgentError.unreachable("") })
        let copy = GuestCopy(direction: .toGuest, sources: ["/nonexistent-\(UUID().uuidString)"], destination: "d")
        #expect(try await agent.copy(copy) { _, _ in } == 1)
    }

    /// `hobo cp vm:tree renamed`: a single source becomes the destination itself, and the
    /// staging directory it was extracted into is gone.
    @Test func getOfASingleSourceBecomesTheDestination() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let guest = dir.appending(path: "guest")
        try FileManager.default.createDirectory(at: guest.appending(path: "tree"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: guest.appending(path: "tree/a.txt"))
        let stream = try tar(["-c", "-f", "-", "-C", guest.path, "tree"])
        let host = dir.appending(path: "host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let seen = Seen()
        let agent = guestAgent { request, socket in
            seen.record(request)
            try socket.writeFrame(.data, stream)
            try socket.writeFrame(.data, Data())
            try sendExit(0, on: socket)
        }
        let copy = GuestCopy(direction: .fromGuest, sources: ["tree"], destination: host.appending(path: "renamed").path)
        #expect(try await agent.copy(copy) { _, _ in } == 0)
        #expect(seen.field("op") == "get")
        #expect(try String(contentsOf: host.appending(path: "renamed/a.txt"), encoding: .utf8) == "a")
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.path) == ["renamed"])
    }

    /// `hobo cp --replace vm:tree out/`: the tree that was in `out` goes, its neighbours stay, and
    /// no staging directory is left.
    @Test func getWithReplaceRemovesWhatASourceLandsOn() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let guest = dir.appending(path: "guest")
        try FileManager.default.createDirectory(at: guest.appending(path: "tree"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: guest.appending(path: "tree/new.txt"))
        let stream = try tar(["-c", "-f", "-", "-C", guest.path, "tree"])
        let host = dir.appending(path: "host")
        try FileManager.default.createDirectory(at: host.appending(path: "tree"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: host.appending(path: "tree/stale.txt"))
        try Data("other".utf8).write(to: host.appending(path: "other.txt"))
        let agent = guestAgent { _, socket in
            try socket.writeFrame(.data, stream)
            try socket.writeFrame(.data, Data())
            try sendExit(0, on: socket)
        }
        let merge = GuestCopy(direction: .fromGuest, sources: ["tree"], destination: host.path)
        #expect(try await agent.copy(merge) { _, _ in } == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.appending(path: "tree").path).sorted() == ["new.txt", "stale.txt"])
        let replace = GuestCopy(direction: .fromGuest, sources: ["tree"], destination: host.path, replace: true)
        #expect(try await agent.copy(replace) { _, _ in } == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.appending(path: "tree").path) == ["new.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.path).sorted() == ["other.txt", "tree"])
    }

    /// A guest that has nothing to send (its source is missing) fails the copy, and what `--replace`
    /// would have removed is still there.
    @Test func getWithReplaceKeepsTheDestinationWhenNothingArrives() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "tree"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: dir.appending(path: "tree/stale.txt"))
        let agent = guestAgent { _, socket in
            try socket.writeFrame(.data, Data())
            try sendExit(1, on: socket)
        }
        let copy = GuestCopy(direction: .fromGuest, sources: ["tree"], destination: dir.path, replace: true)
        #expect(try await agent.copy(copy) { _, _ in } == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tree"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "tree").path) == ["stale.txt"])
    }

    @Test func putAsksTheAgentToReplace() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("one".utf8).write(to: dir.appending(path: "one.txt"))
        let seen = Seen()
        let agent = guestAgent { request, socket in
            seen.record(request)
            _ = try receiveData(socket)
            try sendExit(0, on: socket)
        }
        let copy = GuestCopy(direction: .toGuest, sources: [dir.appending(path: "one.txt").path], destination: "dest", replace: true)
        #expect(try await agent.copy(copy) { _, _ in } == 0)
        #expect(seen.field("replace") == "1")
        #expect(seen.field("single") == "1")
    }

    @Test func getIntoAnExistingDirectoryKeepsTheSourcesNames() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("one".utf8).write(to: dir.appending(path: "one.txt"))
        let stream = try tar(["-c", "-f", "-", "-C", dir.path, "one.txt"])
        let host = dir.appending(path: "host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let agent = guestAgent { _, socket in
            try socket.writeFrame(.data, stream)
            try socket.writeFrame(.data, Data())
            try sendExit(0, on: socket)
        }
        let copy = GuestCopy(direction: .fromGuest, sources: ["one.txt", "two.txt"], destination: host.path)
        #expect(try await agent.copy(copy) { _, _ in } == 0)
        #expect(try String(contentsOf: host.appending(path: "one.txt"), encoding: .utf8) == "one")
    }

    /// Like scp, a destination that has to be a directory and isn't fails before anything is asked of the guest.
    @Test func getRefusesADestinationThatIsntTheDirectoryItMustBe() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = GuestAgent(connect: { Issue.record("connected"); throw AgentError.unreachable("") })
        let output = Output()
        let slashed = GuestCopy(direction: .fromGuest, sources: ["a"], destination: dir.appending(path: "missing").path + "/")
        #expect(try await agent.copy(slashed, onOutput: output.append) == 1)
        #expect(output.text(.stderr).contains("no such directory"))
        let several = GuestCopy(direction: .fromGuest, sources: ["a", "b"], destination: dir.appending(path: "file").path)
        #expect(try await agent.copy(several, onOutput: output.append) == 1)
        #expect(output.text(.stderr).contains("not a directory"))
    }

    /// A stream tar can't extract fails the copy, and leaves no staging directory behind.
    @Test func getFailsWhenTheHostsTarDoes() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = guestAgent { _, socket in
            try socket.writeFrame(.data, Data(repeating: 0x41, count: 4096))
            try socket.writeFrame(.data, Data())
            try sendExit(0, on: socket)
        }
        let output = Output()
        let copy = GuestCopy(direction: .fromGuest, sources: ["a"], destination: dir.appending(path: "out").path)
        #expect(try await agent.copy(copy, onOutput: output.append) == 1)
        #expect(output.text(.stderr).hasPrefix("tar: "))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    // MARK: Clipboard

    /// Every clipboard text the host sends, until it hangs up.
    func receiveTexts(_ socket: AgentSocket, count: Int) throws -> [String] {
        var texts: [String] = []
        var text = Data()
        while texts.count < count, let (kind, payload) = try socket.readFrame() {
            guard kind == .text else { throw AgentError.unexpectedFrame(kind) }
            if payload.isEmpty { texts.append(String(decoding: text, as: UTF8.self)); text = Data() } else { text += payload }
        }
        return texts
    }

    func sendText(_ text: String, on socket: AgentSocket) throws {
        try socket.writeFrame(.text, Data(text.utf8))
        try socket.writeFrame(.text, Data())
    }

    @Test func clipboardSendsAndReceivesTextsWholeAcrossFrames() async throws {
        let seen = Seen()
        let fromHost = Mutex<[String]>([])
        let big = String(repeating: "é", count: AgentFrame.maxPayload) // Two frames' worth of UTF-8.
        let agent = guestAgent { request, socket in
            seen.record(request)
            let texts = try receiveTexts(socket, count: 2)
            fromHost.withLock { $0 = texts }
            try sendText(big, on: socket)
            // Over the limit: dropped whole, and the next still arrives.
            try sendText(String(repeating: "x", count: ClipboardSync.maxText + 1), on: socket)
            try sendText("after", on: socket)
            try sendExit(0, on: socket)
        }
        let (outgoing, continuation) = AsyncStream.makeStream(of: String.self)
        continuation.yield("one")
        continuation.yield("two\nlines")
        let received = Mutex<[String]>([])
        let status = try await agent.clipboard(outgoing: outgoing) { text in received.withLock { $0.append(text) } }
        #expect(status == 0)
        #expect(seen.fields == ["version": "1", "op": "clipboard", "user": Conventions.username])
        #expect(fromHost.withLock { $0 } == ["one", "two\nlines"])
        #expect(received.withLock { $0 } == [big, "after"])
    }

    @Test func cancellingTheClipboardHangsUp() async throws {
        let hungUp = Mutex(false)
        let agent = guestAgent { _, socket in
            // Waits for the host to hang up, as the agent's relay does.
            while (try? socket.readFrame()) != nil {}
            hungUp.withLock { $0 = true }
        }
        let (outgoing, _) = AsyncStream.makeStream(of: String.self)
        let task = Task { try await agent.clipboard(outgoing: outgoing) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(hungUp.withLock { $0 })
    }
}
