import CryptoKit
import Foundation

/// The IPSW cache, `~/.hobo/depot/<sha256>.ipsw`. `index.json` remembers which URL produced
/// which hash, so an unpinned `latest` source is downloaded only once.
public struct Depot: Sendable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public func file(sha256: String) -> URL { directory.appending(path: "\(sha256).ipsw") }

    /// Returns the cached file for `url`, downloading and verifying it if needed.
    /// With no `expectedSHA256`, the computed hash is trusted and recorded.
    public func fetch(
        _ url: URL, expectedSHA256: String?, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (file: URL, sha256: String) {
        if let sha = expectedSHA256 ?? index()[url.absoluteString],
           FileManager.default.fileExists(atPath: file(sha256: sha).path) {
            return (file(sha256: sha), sha)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let part = directory.appending(path: "download.part")
        try? FileManager.default.removeItem(at: part)
        try await Download(url: url, destination: part, progress: progress).run()

        let sha = try Self.sha256(of: part)
        if let expectedSHA256, sha != expectedSHA256 {
            try? FileManager.default.removeItem(at: part)
            throw DepotError.checksumMismatch(url.absoluteString, expected: expectedSHA256, actual: sha)
        }
        let destination = file(sha256: sha)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
        var entries = index()
        entries[url.absoluteString] = sha
        try JSONEncoder.sorted.encode(entries).write(to: indexURL, options: .atomic)
        return (destination, sha)
    }

    /// Verifies a local IPSW against its pinned hash.
    public static func verify(_ file: URL, sha256 expected: String) throws {
        let actual = try sha256(of: file)
        if actual != expected { throw DepotError.checksumMismatch(file.path, expected: expected, actual: actual) }
    }

    public static func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        try hasher.update(contentsOf: file)
        return hasher.finalize().hexString
    }

    private var indexURL: URL { directory.appending(path: "index.json") }

    private func index() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

public enum DepotError: Error, Equatable, CustomStringConvertible {
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
        // Each chunk is autoreleased; without a pool per chunk, hashing a 28 GB box keeps
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
            finish(DepotError.httpStatus(url.absoluteString, http.statusCode))
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
