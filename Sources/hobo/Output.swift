import ArgumentParser
import Foundation
import HoboCore

/// A command that prints a result, and so supports `--json`. Conforming is the whole of its
/// `--json` support: the shared `run()` builds the `Output`, hands `execute` its `log` for progress,
/// prints the one `Reply` in the right format, and reports a thrown error as JSON. `execute` must
/// not print; text-only interaction (`delete`'s prompt) belongs where `--json` can't reach.
protocol OutputCommand: AsyncParsableCommand {
    /// The command's `--json` flag, declared by each command for its own help text.
    var json: Bool { get }
    /// A JSON document, or JSON Lines events for a command with progress. No default: each
    /// command decides, since the wrong one drops its progress or breaks its format.
    static var jsonStyle: Output.JSONStyle { get }
    func execute(_ output: Output) async throws -> Reply
}

extension OutputCommand {
    func run() async throws {
        let output = Output(json: json, style: Self.jsonStyle)
        try await output.reporting {
            output.result(try await execute(output))
        }
    }
}

/// A command's outcome, for people (`text`) and as JSON (`value`).
struct Reply {
    let value: any Encodable
    let text: String

    init(_ value: some Encodable, text: String) {
        self.value = value
        self.text = text
    }
}

/// Where a command's output goes. Text is for people. With `--json`, a command that finishes
/// quickly prints one JSON document, and one with progress (`create`, `start`, `stop`) prints
/// JSON Lines: `{"event":"log","message":…}` as it goes, then `{"event":"result","result":…}`.
/// A failure is JSON on stdout too, `{"error":…}` or `{"event":"error","error":…}`, with exit status 1.
struct Output: Sendable {
    enum JSONStyle: Sendable { case document, events }
    enum Format: Sendable { case text, document, events }

    let format: Format

    init(json: Bool, style: JSONStyle) {
        switch (json, style) {
        case (false, _): format = .text
        case (true, .document): format = .document
        case (true, .events): format = .events
        }
    }

    var isJSON: Bool { format != .text }

    /// Progress: a line of text, or a `log` event. A JSON document has no room for it, so it's dropped.
    func log(_ message: String) {
        switch format {
        case .text: print(message)
        case .events: Self.writeLine(LogEvent(message: message.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .document: break
        }
    }

    /// The command's outcome, printed once by `OutputCommand.run`.
    fileprivate func result(_ reply: Reply) {
        emit(reply.value, text: reply.text)
    }

    private func emit(_ value: some Encodable, text: String) {
        switch format {
        case .text: print(text)
        case .document: Self.write(Self.encoded { try HoboJSON.document(value) })
        case .events: Self.writeLine(ResultEvent(result: value))
        }
    }

    /// For a ^C handler: says what was left behind, as text or as an `error` event.
    func interrupted(_ consequence: String) {
        switch format {
        case .text: print("\nInterrupted; \(consequence)")
        case .document, .events: fail("interrupted; \(consequence)")
        }
    }

    /// Reports a failure the way the format calls for. In text mode it is left to ArgumentParser.
    private func fail(_ message: String) {
        switch format {
        case .text: break
        case .document: Self.write(Self.encoded { try HoboJSON.document(["error": message]) })
        case .events: Self.writeLine(ErrorEvent(error: message))
        }
    }

    /// Runs a command's body, reporting what it throws as JSON in JSON mode.
    fileprivate func reporting(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error where isJSON && !(error is ExitCode) && !(error is CleanExit) {
            fail(String(describing: error))
            throw ExitCode.failure
        }
    }

    private struct LogEvent: Encodable {
        let event = "log"
        var message: String
    }

    private struct ResultEvent<Result: Encodable>: Encodable {
        let event = "result"
        var result: Result
    }

    private struct ErrorEvent: Encodable {
        let event = "error"
        var error: String
    }

    /// Log callbacks arrive on several threads; each JSON line goes out whole, at once (unbuffered,
    /// so an agent reading a pipe sees progress as it happens).
    private static let lock = NSLock()

    private static func writeLine(_ value: some Encodable) {
        write(encoded { try HoboJSON.line(value) })
    }

    private static func write(_ data: Data) {
        lock.withLock { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
    }

    /// Hobo's output types always encode; a failure here is a bug, not a user error.
    private static func encoded(_ encode: () throws -> Data) -> Data {
        do { return try encode() } catch { fatalError("can't encode output as JSON: \(error)") }
    }
}
