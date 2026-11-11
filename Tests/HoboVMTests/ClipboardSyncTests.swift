import Foundation
import Synchronization
import Testing
@testable import HoboVM

/// The host's half of the shared clipboard, against a stand-in pasteboard and a stand-in agent
/// request. Needs no VM.
@MainActor
@Suite struct ClipboardSyncTests {
    final class FakePasteboard: HostPasteboard {
        private let state = Mutex<(count: Int, text: String?, reads: Int)>((0, nil, 0))
        let refuses: Bool
        /// When set, each read waits for a signal on it: a read the paste privacy alert holds up.
        let gate: DispatchSemaphore?

        init(refuses: Bool = false, gate: DispatchSemaphore? = nil) {
            self.refuses = refuses
            self.gate = gate
        }

        var changeCount: Int { state.withLock { $0.count } }
        var refusesReads: Bool { refuses }
        var reads: Int { state.withLock { $0.reads } }
        var text: String? { state.withLock { $0.text } }

        func string() -> String? {
            let text = state.withLock { $0.reads += 1; return $0.text }
            gate?.wait()
            return text
        }

        func setString(_ text: String) -> Int {
            state.withLock { $0.count += 1; $0.text = text; return $0.count }
        }

        /// The host's user copying `text`.
        func copy(_ text: String) { _ = setString(text) }
    }

    /// The agent's request: records what the host sends, and lets the test send the guest's copies.
    final class FakeRequest: Sendable {
        let sent = Mutex<[String]>([])
        let opens = Mutex(0)
        let toHost = Mutex<(@Sendable (String) -> Void)?>(nil)
        /// The status each request ends with at once; nil keeps it open until cancelled.
        let status: Int32?

        init(status: Int32? = nil) { self.status = status }

        func open(_ outgoing: AsyncStream<String>, _ onText: @escaping @Sendable (String) -> Void) async throws -> Int32 {
            opens.withLock { $0 += 1 }
            toHost.withLock { $0 = onText }
            if let status { return status }
            for await text in outgoing { sent.withLock { $0.append(text) } }
            throw CancellationError()
        }

        func guestCopies(_ text: String) { toHost.withLock { $0 }?(text) }
        var texts: [String] { sent.withLock { $0 } }
    }

    final class Key { var isKey = true }

    func sync(_ pasteboard: FakePasteboard, _ request: FakeRequest, key: Key, log: @escaping (String) -> Void = { _ in }) -> ClipboardSync {
        ClipboardSync(
            pasteboard: pasteboard, poll: .milliseconds(5), retry: .milliseconds(5),
            open: request.open, isKey: { key.isKey }, log: log
        )
    }

    func eventually(_ what: Comment, _ check: () -> Bool) async throws {
        // Generous: other suites keep the main actor busy when they run alongside.
        let deadline = ContinuousClock.now + .seconds(10)
        while !check() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func theHostsCopiesGoOnlyWhileTheWindowIsKey() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.copy("before the window")
        let request = FakeRequest()
        let key = Key()
        key.isKey = false
        let clipboard = sync(pasteboard, request, key: key)
        clipboard.start()
        try await Task.sleep(for: .milliseconds(30))
        #expect(request.texts.isEmpty)
        #expect(pasteboard.reads == 0)

        key.isKey = true
        try await eventually("the host's text to go") { request.texts == ["before the window"] }
        // Unchanged since, so not read or sent again.
        try await Task.sleep(for: .milliseconds(30))
        #expect(pasteboard.reads == 1)
        pasteboard.copy("later")
        try await eventually("the host's change to go") { request.texts == ["before the window", "later"] }
        clipboard.stop()
    }

    @Test func theGuestsCopiesReplaceTheHostsAndArentSentBack() async throws {
        let pasteboard = FakePasteboard()
        let request = FakeRequest()
        let clipboard = sync(pasteboard, request, key: Key())
        clipboard.start()
        try await eventually("the request to open") { request.toHost.withLock { $0 } != nil }
        // The window coming to the front reads the (empty) pasteboard once.
        try await eventually("the first look") { pasteboard.reads == 1 }
        request.guestCopies("from the guest")
        try await eventually("the host's pasteboard to change") { pasteboard.text == "from the guest" }
        try await Task.sleep(for: .milliseconds(30))
        // The change it made is known, so it isn't read back, let alone sent.
        #expect(request.texts.isEmpty)
        #expect(pasteboard.reads == 1)
        clipboard.stop()
    }

    @Test func theHostsCRLFGoesAsLF() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.copy("one\r\ntwo\r\n")
        let request = FakeRequest()
        let clipboard = sync(pasteboard, request, key: Key())
        clipboard.start()
        try await eventually("the host's text to go") { request.texts == ["one\ntwo\n"] }
        // The guest's clipboard then holds the LF text, which isn't new to the host.
        request.guestCopies("one\ntwo\n")
        try await Task.sleep(for: .milliseconds(30))
        #expect(pasteboard.text == "one\r\ntwo\r\n")
        clipboard.stop()
    }

    @Test(arguments: [
        ("a\r\nb\nc", "a\nb\nc"), ("a\r\r\nb", "a\nb"), ("a\rb\r", "a\rb\r"), ("\r\n\r\n", "\n\n"), ("plain é", "plain é"),
    ])
    func wireTextIsTheAgents(text: String, wire: String) {
        #expect(ClipboardSync.wireText(text) == wire)
        #expect(ClipboardSync.wireText(wire) == wire)
    }

    @Test func aGuestCopyDuringAHostReadWins() async throws {
        let gate = DispatchSemaphore(value: 0)
        let pasteboard = FakePasteboard(gate: gate)
        pasteboard.copy("older, on the host")
        let request = FakeRequest()
        let clipboard = sync(pasteboard, request, key: Key())
        clipboard.start()
        try await eventually("the read to start") { pasteboard.reads == 1 && request.toHost.withLock { $0 } != nil }
        request.guestCopies("newer, from the guest")
        try await eventually("the host's pasteboard to change") { pasteboard.text == "newer, from the guest" }
        gate.signal()
        try await Task.sleep(for: .milliseconds(30))
        #expect(request.texts.isEmpty)
        #expect(pasteboard.text == "newer, from the guest")
        clipboard.stop()
    }

    @Test func theHostsTextOverTheLimitIsLoggedAndNotSent() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.copy(String(repeating: "x", count: ClipboardSync.maxText + 1))
        let request = FakeRequest()
        let logged = Mutex<[String]>([])
        let clipboard = sync(pasteboard, request, key: Key()) { line in logged.withLock { $0.append(line) } }
        clipboard.start()
        try await eventually("the skip to be logged") { !logged.withLock { $0 }.isEmpty }
        pasteboard.copy("small")
        try await eventually("the next text to go") { request.texts == ["small"] }
        clipboard.stop()
        #expect(logged.withLock { $0 }.first?.contains("over the \(ClipboardSync.maxText)-byte limit") == true)
    }

    @Test func nothingIsSharedOnceStopped() async throws {
        let pasteboard = FakePasteboard()
        let request = FakeRequest()
        let clipboard = sync(pasteboard, request, key: Key())
        clipboard.start()
        try await eventually("the request to open") { request.toHost.withLock { $0 } != nil }
        clipboard.stop()
        request.guestCopies("after the window hid")
        pasteboard.copy("on the host")
        try await Task.sleep(for: .milliseconds(30))
        #expect(pasteboard.text == "on the host")
        #expect(request.texts.isEmpty)
    }

    @Test func aRefusedReadIsLoggedOnceAndNeverTried() async throws {
        let pasteboard = FakePasteboard(refuses: true)
        pasteboard.copy("secret")
        let request = FakeRequest()
        let logged = Mutex<[String]>([])
        let clipboard = sync(pasteboard, request, key: Key()) { line in logged.withLock { $0.append(line) } }
        clipboard.start()
        try await eventually("the refusal to be logged") { !logged.withLock { $0 }.isEmpty }
        pasteboard.copy("another")
        try await Task.sleep(for: .milliseconds(30))
        clipboard.stop()
        #expect(pasteboard.reads == 0)
        #expect(request.texts.isEmpty)
        #expect(logged.withLock { $0 }.count == 1)
    }

    @Test func aGuestWithoutItsDesktopIsRetriedAndLoggedOnce() async throws {
        let request = FakeRequest(status: GUISession.unavailableStatus)
        let logged = Mutex<[String]>([])
        let clipboard = sync(FakePasteboard(), request, key: Key()) { line in logged.withLock { $0.append(line) } }
        clipboard.start()
        try await eventually("a retry") { request.opens.withLock { $0 } >= 3 }
        clipboard.stop()
        #expect(logged.withLock { $0 } == ["clipboard: waiting for the guest's desktop session; retrying every 0.005 seconds"])
    }
}
