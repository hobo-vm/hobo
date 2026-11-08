import Foundation
import Testing
@testable import HoboCore

@Suite struct ImageIndexTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "hobo-images-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Downloads") }
    var served: URL { root.appending(path: "served") }
    var index: ImageIndex { ImageIndex(indexFile: root.appending(path: "hobo/images.json"), downloads: downloads) }
    let payload = Data((0..<300_000).map { UInt8($0 % 251) })

    init() throws {
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try payload.write(to: served.appending(path: "mac.ipsw"))
    }

    private func entries() throws -> [String: ImageIndex.Entry] {
        try JSONDecoder().decode([String: ImageIndex.Entry].self, from: Data(contentsOf: index.indexFile))
    }

    private func downloaded() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: downloads.path).sorted()
    }

    @Test func hashesFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = served.appending(path: "mac.ipsw")
        #expect(try ImageIndex.sha256(of: file) == shasum(file))
    }

    @Test func downloadsVerifiesIndexesAndReuses() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sha = try shasum(served.appending(path: "mac.ipsw"))
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let url = server.url(for: "mac.ipsw")

        // Unpinned: the computed hash is trusted and recorded.
        let fetched = try await index.fetch(url, expectedSHA256: nil) { _, _ in }
        #expect(fetched.sha256 == sha)
        #expect(fetched.file == downloads.appending(path: "mac.ipsw"))
        #expect(try downloaded() == ["mac.ipsw"])
        let entry = try #require(try entries()[url.absoluteString])
        #expect(entry.sha256 == sha && entry.path == fetched.file.standardizedFileURL.path && entry.size == UInt64(payload.count))

        // Cached: served from the index with the server gone, and pinned or not.
        server.stop()
        #expect(try await index.fetch(url, expectedSHA256: nil) { _, _ in }.file == fetched.file)
        #expect(try await index.fetch(url, expectedSHA256: sha) { _, _ in }.file == fetched.file)
    }

    @Test func unchangedFileIsNotRehashedButChangedOneIs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let url = server.url(for: "mac.ipsw")
        let fetched = try await index.fetch(url, expectedSHA256: nil) { _, _ in }

        // Same size and mtime: the recorded hash is trusted, so a doctored entry wins.
        var doctored = try entries()
        let fake = String(repeating: "a", count: 64)
        doctored[url.absoluteString]!.sha256 = fake
        try JSONEncoder().encode(doctored).write(to: index.indexFile)
        #expect(try await index.fetch(url, expectedSHA256: nil) { _, _ in }.sha256 == fake)

        // A touched file is rehashed and the entry corrected.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: fetched.file.path)
        #expect(try await index.fetch(url, expectedSHA256: nil) { _, _ in }.sha256 == fetched.sha256)
        #expect(try entries()[url.absoluteString]?.sha256 == fetched.sha256)
    }

    @Test func missingFileIsDownloadedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let url = server.url(for: "mac.ipsw")
        let fetched = try await index.fetch(url, expectedSHA256: nil) { _, _ in }
        try FileManager.default.removeItem(at: fetched.file)
        #expect(try await index.fetch(url, expectedSHA256: fetched.sha256) { _, _ in }.file == fetched.file)
        #expect(try downloaded() == ["mac.ipsw"])
    }

    @Test func adoptsMatchingUnindexedFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try payload.write(to: downloads.appending(path: "mac.ipsw"))
        let sha = try shasum(served.appending(path: "mac.ipsw"))
        // An unreachable URL proves no download happens.
        let url = URL(string: "https://invalid.invalid/mac.ipsw")!
        let fetched = try await index.fetch(url, expectedSHA256: sha) { _, _ in }
        #expect(fetched.file == downloads.appending(path: "mac.ipsw"))
        #expect(try entries()[url.absoluteString]?.sha256 == sha)
    }

    @Test func mismatchedUnindexedFileIsLeftAloneAndDownloadGetsAFreeName() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let theirs = Data("someone else's file".utf8)
        try theirs.write(to: downloads.appending(path: "mac.ipsw"))
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let sha = try shasum(served.appending(path: "mac.ipsw"))

        let fetched = try await index.fetch(server.url(for: "mac.ipsw"), expectedSHA256: sha) { _, _ in }
        #expect(fetched.file == downloads.appending(path: "mac 2.ipsw"))
        #expect(try Data(contentsOf: downloads.appending(path: "mac.ipsw")) == theirs)
        #expect(try downloaded() == ["mac 2.ipsw", "mac.ipsw"])
    }

    @Test func indexedFileNotMatchingThePinIsKeptAndAFreshCopyDownloaded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let url = server.url(for: "mac.ipsw")
        let old = try await index.fetch(url, expectedSHA256: nil) { _, _ in }

        // The vendor replaces the file behind the URL and the recipe is re-pinned to it.
        try Data("a newer build".utf8).write(to: served.appending(path: "mac.ipsw"))
        let sha = try shasum(served.appending(path: "mac.ipsw"))
        let fetched = try await index.fetch(url, expectedSHA256: sha) { _, _ in }
        #expect(fetched.file == downloads.appending(path: "mac 2.ipsw"))
        #expect(try Data(contentsOf: old.file) == payload)
        #expect(try entries()[url.absoluteString]?.path == fetched.file.standardizedFileURL.path)
    }

    @Test func corruptIndexIsTreatedAsEmpty() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: index.indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: index.indexFile)
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let url = server.url(for: "mac.ipsw")
        let fetched = try await index.fetch(url, expectedSHA256: nil) { _, _ in }
        #expect(try entries()[url.absoluteString]?.sha256 == fetched.sha256)
    }

    @Test func rejectsWrongHashAndHTTPErrors() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let wrong = String(repeating: "0", count: 64)

        await #expect(throws: ImageError.self) {
            try await index.fetch(server.url(for: "mac.ipsw"), expectedSHA256: wrong) { _, _ in }
        }
        #expect(try downloaded().isEmpty)
        await #expect(throws: ImageError.httpStatus(server.url(for: "missing.ipsw").absoluteString, 404)) {
            try await index.fetch(server.url(for: "missing.ipsw"), expectedSHA256: nil) { _, _ in }
        }
        #expect(try downloaded().isEmpty)
    }

    @Test func stalePartFileIsReplaced() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("half a download".utf8).write(to: downloads.appending(path: "mac.ipsw.part"))
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let sha = try shasum(served.appending(path: "mac.ipsw"))
        #expect(try await index.fetch(server.url(for: "mac.ipsw"), expectedSHA256: sha) { _, _ in }.sha256 == sha)
        #expect(try downloaded() == ["mac.ipsw"])
    }

    @Test(arguments: [
        ("https://h.example/a/mac.ipsw?x=1", "mac.ipsw"), ("https://h.example/a/b%2Fc.ipsw", "b_c.ipsw"),
        ("https://h.example/", "image.ipsw"), ("https://h.example", "image.ipsw"),
        ("https://h.example/a/..", "image.ipsw"), ("https://h.example/a/.", "image.ipsw"),
    ])
    func downloadNameStaysInsideDownloads(url: String, name: String) {
        #expect(ImageIndex.filename(for: URL(string: url)!) == name)
    }

    @Test func localFilesAreVerifiedInPlaceAndIndexed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = served.appending(path: "mac.ipsw")
        let sha = try shasum(file)
        #expect(throws: ImageError.self) { try index.verify(file, sha256: String(repeating: "0", count: 64)) }
        try index.verify(file, sha256: sha)
        #expect(try entries()[file.standardizedFileURL.path]?.sha256 == sha)
        #expect(!FileManager.default.fileExists(atPath: downloads.path))

        // Unchanged: the recorded hash is trusted without rehashing.
        var doctored = try entries()
        let fake = String(repeating: "b", count: 64)
        doctored[file.standardizedFileURL.path]!.sha256 = fake
        try JSONEncoder().encode(doctored).write(to: index.indexFile)
        try index.verify(file, sha256: fake)
    }

    /// What `hobo init` does then `hobo create`: the pin's hash is the one verifying it reuses.
    @Test func verifyingAHashJustTakenDoesntHashAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = served.appending(path: "mac.ipsw")
        #expect(try index.hash(of: file) == (try shasum(file)))

        var doctored = try entries()
        let fake = String(repeating: "c", count: 64)
        doctored[file.standardizedFileURL.path]!.sha256 = fake
        try JSONEncoder().encode(doctored).write(to: index.indexFile)
        try index.verify(file, sha256: fake)
    }

    /// An ISO is often a link to a download elsewhere; what counts is whether that has changed.
    @Test func aChangeBehindASymbolicLinkIsNoticed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = served.appending(path: "target.iso")
        try Data("first".utf8).write(to: target)
        let link = served.appending(path: "link.iso")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let first = try index.hash(of: link)

        try Data("second, and longer".utf8).write(to: target)
        let second = try index.hash(of: link)
        #expect(second != first)
        #expect(second == (try shasum(target)))
    }

    private func shasum(_ file: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(output.prefix(64))
    }
}

@Suite struct DHCPLeasesTests {
    let leases = """
    {
    	name=Mac
    	ip_address=192.168.64.5
    	hw_address=1,a2:b:c:d0:e:f
    	identifier=1,a2:b:c:d0:e:f
    	lease=0x6720b1c9
    }
    {
    	name=other
    	ip_address=192.168.64.4
    	hw_address=1,11:22:33:44:55:66
    	lease=0x6720b1c0
    }
    """

    @Test func findsIPByZeroPaddedMAC() {
        #expect(DHCPLeases.ipAddress(forMAC: "A2:0B:0C:D0:0E:0F", in: leases) == "192.168.64.5")
        #expect(DHCPLeases.ipAddress(forMAC: "11:22:33:44:55:66", in: leases) == "192.168.64.4")
        #expect(DHCPLeases.ipAddress(forMAC: "11:22:33:44:55:67", in: leases) == nil)
        #expect(DHCPLeases.ipAddress(forMAC: "garbage", in: leases) == nil)
    }
}

@Suite struct ByteSizeTests {
    @Test(arguments: [(UInt64(8) << 30, "8GB"), (1536 << 20, "1536MB"), (1 << 40, "1TB"), (100, "100B")])
    func byteSizesRoundTrip(bytes: UInt64, text: String) throws {
        #expect(ByteSize(bytes: bytes).description == text)
        #expect(try ByteSize(parsing: text).bytes == bytes)
    }

    @Test(arguments: ["8", "eight GB", "GB", "-1GB", "99999999999TB"])
    func invalidSizesAreRejected(text: String) {
        #expect(throws: RecipeError.invalidSize(text)) { try ByteSize(parsing: text) }
    }
}

@Suite struct ConventionsTests {
    @Test func embeddedPrivateKeyMatchesPublicKey() throws {
        let home = HoboHome(root: FileManager.default.temporaryDirectory.appending(path: "hobo-home-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }
        let key = try home.ensureInsecurePrivateKey()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", key.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let derived = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let keyBody = { (line: String) in line.split(separator: " ").prefix(2).joined(separator: " ") }
        #expect(keyBody(derived) == keyBody(Conventions.insecurePublicKey))
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(shellQuote("it's") == #"'it'\''s'"#)
    }
}

/// `python3 -m http.server` on a free port, serving `directory`.
final class HTTPServer {
    private let process = Process()
    /// Signalled by the termination handler. `waitUntilExit()` spins the calling thread's run
    /// loop, which on a Swift concurrency thread can miss the exit and hang the test run.
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false
    let port: Int

    init(directory: URL) throws {
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", directory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        // First line: "Serving HTTP on 127.0.0.1 port 54321 (http://127.0.0.1:54321/) ..."
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) {
            line += byte
        }
        let words = String(decoding: line, as: UTF8.self).split(separator: " ")
        guard let index = words.firstIndex(of: "port"), index + 1 < words.count, let port = Int(words[index + 1]) else {
            process.terminate()
            throw CocoaError(.fileReadCorruptFile)
        }
        self.port = port
    }

    func url(for path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }

    func stop() {
        guard !stopped else { return }
        stopped = true
        process.terminate()
        exited.wait()
    }
}
