import CryptoKit
import Foundation

/// Install images on the host. Downloads land in `downloads` (`~/Downloads`) under the vendor's
/// filename, via `<name>.part` until the SHA-256 verifies, so users can see and delete them.
/// `indexFile` (`~/.hobo/images.json`) maps each source (a URL, or a local file's path) to its
/// hash, path, size and mtime, so an unchanged multi-GB file isn't rehashed on every use.
public struct ImageIndex: Sendable {
    public var indexFile: URL
    public var downloads: URL

    public init(indexFile: URL, downloads: URL) {
        self.indexFile = indexFile
        self.downloads = downloads
    }

    public static func standard(home: HoboHome = .standard()) -> ImageIndex {
        ImageIndex(indexFile: home.images, downloads: .downloadsDirectory)
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var sha256: String
        public var path: String
        public var size: UInt64
        /// Seconds since 1970; a Double so it survives the JSON round trip exactly.
        public var mtime: Double
    }

    /// Returns a verified file for `url`, downloading it if no indexed or same-named file in
    /// `downloads` matches. With no `expectedSHA256`, the computed hash is trusted and recorded.
    public func fetch(
        _ url: URL, expectedSHA256: String?, log: @Sendable (String) -> Void = { _ in },
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (file: URL, sha256: String) {
        let key = url.absoluteString
        let accepts = { (sha: String) in expectedSHA256 == nil || sha == expectedSHA256 }
        var entries = load()
        let indexed = try entries[key].flatMap { try refreshed($0, log: log) }
        if let indexed, accepts(indexed.sha256) {
            if indexed != entries[key] { entries[key] = indexed; try save(entries) }
            return (URL(filePath: indexed.path), indexed.sha256)
        }

        // A same-named file nobody indexed, e.g. downloaded in a browser: adopt it if it matches.
        let vendorNamed = downloads.appending(path: Self.filename(for: url))
        let alreadyRejected = indexed?.path == vendorNamed.standardizedFileURL.path
        if !alreadyRejected, FileManager.default.fileExists(atPath: vendorNamed.path) {
            let entry = try Self.entry(for: vendorNamed, log: log)
            if accepts(entry.sha256) {
                entries[key] = entry
                try save(entries)
                return (vendorNamed, entry.sha256)
            }
        }

        let destination = freeName(for: vendorNamed)
        let part = destination.appendingPathExtension("part")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: part)
        defer { try? FileManager.default.removeItem(at: part) }
        log("Downloading \(key) to \(destination.path)")
        try await Download(url: url, destination: part, progress: progress).run()

        let sha = try Self.sha256(of: part, log: log)
        if let expectedSHA256, sha != expectedSHA256 {
            throw ImageError.checksumMismatch(key, expected: expectedSHA256, actual: sha)
        }
        try FileManager.default.moveItem(at: part, to: destination)
        let entry = try Self.entry(for: destination, sha256: sha)
        entries[key] = entry
        try save(entries)
        return (destination, sha)
    }

    /// Verifies a local IPSW, used in place, against its pinned hash. An unchanged file (same size
    /// and mtime as when last hashed) is trusted without rehashing.
    public func verify(_ file: URL, sha256 expected: String, log: @Sendable (String) -> Void = { _ in }) throws {
        let key = file.standardizedFileURL.path
        var entries = load()
        let cached = entries[key]
        let entry = try cached.flatMap { try refreshed($0, log: log) } ?? Self.entry(for: file, log: log)
        if entry != cached {
            entries[key] = entry
            try save(entries)
        }
        if entry.sha256 != expected {
            throw ImageError.checksumMismatch(file.path, expected: expected, actual: entry.sha256)
        }
    }

    public static func sha256(of file: URL, log: @Sendable (String) -> Void = { _ in }) throws -> String {
        log("Hashing \(file.lastPathComponent)")
        var hasher = SHA256()
        try hasher.update(contentsOf: file)
        return hasher.finalize().hexString
    }

    /// `entry` refreshed from disk: as is if size and mtime are unchanged, rehashed if they
    /// changed, nil if the file is gone.
    private func refreshed(_ entry: Entry, log: @Sendable (String) -> Void) throws -> Entry? {
        let file = URL(filePath: entry.path)
        guard let (size, mtime) = Self.stat(file) else { return nil }
        if size == entry.size && mtime == entry.mtime { return entry }
        return try Self.entry(for: file, log: log)
    }

    private static func entry(for file: URL, sha256: String? = nil, log: @Sendable (String) -> Void = { _ in }) throws -> Entry {
        let sha = try sha256 ?? Self.sha256(of: file, log: log)
        guard let (size, mtime) = stat(file) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: file.path]) }
        return Entry(sha256: sha, path: file.standardizedFileURL.path, size: size, mtime: mtime)
    }

    private static func stat(_ file: URL) -> (size: UInt64, mtime: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date
        else { return nil }
        return (size.uint64Value, date.timeIntervalSince1970)
    }

    /// The download's name in `downloads`: the URL's last path component, kept to a single plain
    /// filename. A recipe URL can end in `/`, `.` or `..`, or decode `%2F` to a slash, any of
    /// which would otherwise point outside `downloads` or at a directory.
    static func filename(for url: URL) -> String {
        let name = url.lastPathComponent.replacing("/", with: "_").replacing(":", with: "_")
        return ["", "_", ".", ".."].contains(name) ? "image.ipsw" : name
    }

    /// `file`, or Finder-style `name 2.ext`, `name 3.ext`, ... if it is taken.
    private func freeName(for file: URL) -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var candidate = file
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = "\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = file.deletingLastPathComponent().appending(path: name)
            number += 1
        }
        return candidate
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: indexFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.sorted.encode(entries).write(to: indexFile, options: .atomic)
    }
}

public enum ImageError: Error, Equatable, CustomStringConvertible {
    case checksumMismatch(String, expected: String, actual: String)
    case httpStatus(String, Int)

    public var description: String {
        switch self {
        case .checksumMismatch(let what, let expected, let actual):
            "sha256 mismatch for \(what): expected \(expected), got \(actual)"
        case .httpStatus(let url, let status): "download of \(url) failed with HTTP \(status)"
        }
    }
}

extension SHA256 {
    /// Feeds `file` to the hasher in 8 MB chunks.
    mutating func update(contentsOf file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Each chunk is autoreleased; without a pool per chunk, hashing a multi-GB IPSW keeps
        // every chunk alive until the loop ends and the process is killed for memory.
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
            update(data: chunk)
            return true
        }) {}
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// One download task that reports progress and moves the finished file to `destination`.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let url: URL
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL, destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.progress = progress
    }

    func run() async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(ImageError.httpStatus(url.absoluteString, http.statusCode))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
