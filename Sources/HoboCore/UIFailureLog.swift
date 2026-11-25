import Foundation

/// The record of `hobo ui` commands that failed, `~/.hobo/ui-failures.log`: each with its command
/// line, its exit status and what it printed, the newest last. A script's check that discards a
/// command's output (`hobo ui … wait … >/dev/null 2>&1`) leaves no other trace of why it failed,
/// and an ephemeral VM is gone by the time anyone asks. It is the host's file rather than the
/// VM's, so it outlives the VM.
public struct UIFailureLog: Sendable {
    public var file: URL
    /// The file's size limit in bytes. Past it the oldest entries go, down to half of it.
    public var limit: Int

    public init(file: URL, limit: Int = 1 << 20) {
        self.file = file
        self.limit = limit
    }

    /// What starts an entry's first line, and nothing else in the file: output lines that start
    /// with it are indented.
    static let marker = "=== "

    /// The most of one command's output an entry keeps, so one entry can't push out all the others.
    public var outputLimit: Int { limit / 4 }

    /// The entry for a `hobo ui <vm> <arguments>` that ended with `result` (`exit 1`, or the error
    /// that kept it from running) after printing `output`.
    static func entry(vm: String, arguments: [String], result: String, output: Data, at date: Date) -> String {
        let words = (["hobo", "ui", vm] + arguments).map { word in
            word.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil ? word : shellQuote(word)
        }
        let body = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        // The command line has lines of its own when an argument does (`type` with a file's text).
        let heading = "\(date.formatted(.iso8601)) \(words.joined(separator: " ")): \(result)"
        let lines = (heading + (body.isEmpty ? "" : "\n" + body)).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(marker) ? " " + $0 : String($0) }
        return marker + lines.joined(separator: "\n") + "\n\n"
    }

    /// Adds an entry, then drops the oldest entries if the file has outgrown its limit. Under a
    /// lock on the file, since several `hobo ui` commands can fail at once.
    public func record(vm: String, arguments: [String], result: String, output: Data, at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        flock(descriptor, LOCK_EX)
        var kept = output.prefix(outputLimit)
        if kept.count < output.count { kept += Data("\n… (\(output.count - kept.count) more bytes)".utf8) }
        try handle.write(contentsOf: Data(Self.entry(vm: vm, arguments: arguments, result: result, output: kept, at: date).utf8))
        if try handle.offset() > limit { try dropOldestEntries(from: handle) }
    }

    /// Rewrites the file as the entries that start in its newest half-limit of bytes.
    private func dropOldestEntries(from handle: FileHandle) throws {
        try handle.seek(toOffset: 0)
        let all = try handle.readToEnd() ?? Data()
        let newestHalf: Range<Int> = max(0, all.count - limit / 2)..<all.count
        let firstKeptEntry = all.range(of: Data(("\n" + Self.marker).utf8), in: newestHalf)
        // Past the newline that ends the entry before it.
        let start = firstKeptEntry.map { $0.lowerBound + 1 } ?? all.count
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: all[start...])
    }
}
