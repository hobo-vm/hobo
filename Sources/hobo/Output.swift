import ArgumentParser
import Foundation
import HoboCore

/// Where a command's output goes. Text is for people. With `--json`, a command that finishes
/// quickly prints one JSON document, and one with progress (`create`, `start`, `stop`) prints
/// JSON Lines: `{"event":"log","message":…}` as it goes, then `{"event":"result","result":…}`.
/// A failure is JSON on stdout too, `{"error":…}` or `{"event":"error","error":…}`, with exit status 1.
struct Output: Sendable {
    enum Format: Sendable { case text, document, events }

    let format: Format

    init(json: Bool, streaming: Bool = false) {
        if !json {
            format = .text
        } else {
            format = streaming ? .events : .document
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

    /// The command's outcome: `text` for people, `value` as JSON.
    func result(_ value: some Encodable, text: @autoclosure () -> String) {
        switch format {
        case .text: print(text())
        case .document: Self.write(Self.encoded { try HoboJSON.document(value) })
        case .events: Self.writeLine(ResultEvent(result: value))
        }
    }

    /// Reports a failure the way the format calls for. In text mode it is left to ArgumentParser.
    func fail(_ message: String) {
        switch format {
        case .text: break
        case .document: Self.write(Self.encoded { try HoboJSON.document(["error": message]) })
        case .events: Self.writeLine(ErrorEvent(error: message))
        }
    }

    /// Runs a command's body, reporting what it throws as JSON in JSON mode.
    /// Runs on the caller's actor, so `create` keeps the main actor it needs.
    func reporting(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            throw reported(error)
        }
    }

    func reporting(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            throw reported(error)
        }
    }

    private func reported(_ error: any Error) -> any Error {
        guard isJSON, !(error is ExitCode), !(error is CleanExit) else { return error }
        fail(String(describing: error))
        return ExitCode.failure
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
