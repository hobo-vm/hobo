import AppKit

/// The host's pasteboard as `ClipboardSync` uses it: `SystemPasteboard` in the VM process, a stand-in
/// in tests. Reading may put up macOS's paste privacy alert and wait for an answer, so it is never
/// done on the main actor.
protocol HostPasteboard: Sendable {
    /// Changes with every change of the contents; reading it never alerts.
    var changeCount: Int { get }
    /// Whether the user's Paste setting for Hobo refuses programmatic reads, so a read would only
    /// come back empty.
    var refusesReads: Bool { get }
    /// The text it holds, if any.
    func string() -> String?
    /// Replaces its contents with `text`, returning the change count that makes.
    func setString(_ text: String) -> Int
}

/// The general pasteboard.
struct SystemPasteboard: HostPasteboard {
    var changeCount: Int { NSPasteboard.general.changeCount }
    var refusesReads: Bool { NSPasteboard.general.accessBehavior == .alwaysDeny }
    func string() -> String? { NSPasteboard.general.string(forType: .string) }
    func setString(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
}

/// The shared clipboard (decision 17): text, both ways, only while the window shows. Headless VMs,
/// and so every agent session, never see the host's clipboard, and nothing a guest copies lands on
/// the host's while no one is looking. While `start`ed it holds a `clipboard` request open to
/// hobo-agent, reopening it if it ends.
///
/// - Host to guest: when the window is key and the host's pasteboard has changed since it last
///   matched the guest's, its text goes to the guest. Reading it only then, when the user has just
///   come to the window, is what macOS's paste privacy alert is least likely to object to.
/// - Guest to host: each new text the guest copies replaces the host's pasteboard.
///
/// Each side remembers the last text it sent or was given, so nothing echoes back; when both
/// change at once, the later wins.
@MainActor
final class ClipboardSync {
    /// The largest text shared either way, as the agent has it (`maxClipboardText`).
    nonisolated static let maxText = 16 << 20

    typealias OpenRequest = @Sendable (AsyncStream<String>, @escaping @Sendable (String) -> Void) async throws -> Int32

    private let pasteboard: any HostPasteboard
    private let open: OpenRequest
    private let isKey: @MainActor () -> Bool
    private let log: (String) -> Void
    private let poll: Duration
    private let retry: Duration

    /// The request's loop and the host-pasteboard poll, while started.
    private var session: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// Where texts for the guest go, while a request is open.
    private var outgoing: AsyncStream<String>.Continuation?
    /// Counts requests, so a read that outlives its request isn't sent on the next.
    private var requests = 0
    /// The host pasteboard's change count when it last matched the guest's clipboard, or was last
    /// looked at; nil before either.
    private var matchedChangeCount: Int?
    /// The last text sent to the guest or taken from it.
    private var lastText: String?
    /// Whether a read of the host's pasteboard is under way, so a poll doesn't start another.
    private var reading = false
    /// The last problem logged, so a guest that keeps failing the same way logs it once.
    private var lastProblem: String?

    /// `open` opens the agent's `clipboard` request (`GuestAgent.clipboard`); `isKey` says whether
    /// the window is the key window.
    init(
        pasteboard: any HostPasteboard = SystemPasteboard(), poll: Duration = .milliseconds(500), retry: Duration = .seconds(5),
        open: @escaping OpenRequest, isKey: @escaping @MainActor () -> Bool, log: @escaping (String) -> Void
    ) {
        self.pasteboard = pasteboard
        self.poll = poll
        self.retry = retry
        self.open = open
        self.isKey = isKey
        self.log = log
    }

    /// Starts sharing: the window has shown.
    func start() {
        guard session == nil else { return }
        lastProblem = nil
        let deliver: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.received(text) }
        }
        session = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let (stream, continuation) = AsyncStream.makeStream(of: String.self)
                outgoing = continuation
                requests += 1
                hostMayHaveChanged()
                let open = self.open
                let problem: String?
                do {
                    let status = try await open(stream, deliver)
                    problem = status == GUISession.unavailableStatus
                        ? "waiting for the guest's desktop session" : "the clipboard helper exited with status \(status)"
                } catch {
                    problem = Task.isCancelled ? nil : "\(error)"
                }
                continuation.finish()
                if outgoing == nil || Task.isCancelled { return }
                outgoing = nil
                if let problem, problem != lastProblem {
                    log("clipboard: \(problem); retrying every \(retry)")
                    lastProblem = problem
                }
                try? await Task.sleep(for: retry)
            }
        }
        poller = Task { [weak self, poll] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                self?.hostMayHaveChanged()
            }
        }
    }

    /// Stops sharing: the window has hidden, or closed for good.
    func stop() {
        session?.cancel()
        poller?.cancel()
        session = nil
        poller = nil
        outgoing?.finish()
        outgoing = nil
    }

    /// Sends the host's text to the guest if the window is key and the pasteboard has changed
    /// since it last matched. Called when the window becomes key, and on every poll.
    func hostMayHaveChanged() {
        guard let toGuest = outgoing, isKey(), !reading else { return }
        let count = pasteboard.changeCount
        guard count != matchedChangeCount else { return }
        // Looked at once per change, whatever comes of it, so a refused read isn't asked again.
        matchedChangeCount = count
        if pasteboard.refusesReads {
            let problem = "macOS's Paste setting for Hobo is Deny (System Settings > Privacy & Security > Paste), so the guest doesn't get the host's clipboard"
            if problem != lastProblem {
                log("clipboard: \(problem)")
                lastProblem = problem
            }
            return
        }
        reading = true
        let pasteboard = self.pasteboard
        let request = requests
        Task { [weak self] in
            // In wire form, so it compares equal to the same text coming back from the guest, which
            // the agent sends in wire form.
            let text = await Task.detached { pasteboard.string().map(Self.wireText) }.value
            guard let self else { return }
            reading = false
            // A guest copy that landed during the read is newer than what was read: it wins.
            guard matchedChangeCount == count else { return }
            guard let text, !text.isEmpty, text != lastText, outgoing != nil, requests == request else { return }
            guard text.utf8.count <= Self.maxText else {
                log("clipboard: not sharing the host's \(text.utf8.count) bytes of text: over the \(Self.maxText)-byte limit")
                return
            }
            lastText = text
            toGuest.yield(text)
        }
    }

    /// A text's wire form, as the agent's `wireText` (`Agent/clipboard.go`) defines it: a line
    /// ending of CRs then LF becomes LF alone, and a CR anywhere else stays. The agent puts
    /// everything it is sent in this form itself, so its own echo check never depends on this
    /// agreeing; the host's does, for a text that comes back.
    nonisolated static func wireText(_ text: String) -> String {
        guard text.contains("\r\n") else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" { while scalars.last == "\r" { scalars.removeLast() } }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// A text the guest copied: it replaces the host's pasteboard.
    private func received(_ text: String) {
        guard outgoing != nil, text != lastText else { return }
        lastText = text
        matchedChangeCount = pasteboard.setString(text)
    }
}
