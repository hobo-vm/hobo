import Foundation
import Testing
@testable import HoboCore

@Suite struct DepotTests {
    @Test func hashesFiles() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hobo-depot-\(UUID().uuidString)")
        try Data("hobo".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Depot.sha256(of: file) == shasum(file))
        #expect(throws: DepotError.self) { try Depot.verify(file, sha256: String(repeating: "0", count: 64)) }
        try Depot.verify(file, sha256: try shasum(file))
    }

    @Test func cachedFileIsReusedWithoutDownloading() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-depot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let depot = Depot(directory: directory)
        let sha = String(repeating: "0", count: 64)
        try Data().write(to: depot.file(sha256: sha))
        // An unreachable URL proves no network request is made.
        let result = try await depot.fetch(URL(string: "https://invalid.invalid/mac.ipsw")!, expectedSHA256: sha) { _, _ in }
        #expect(result.file == depot.file(sha256: sha))
    }

    @Test func downloadsVerifiesAndIndexes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hobo-depot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let served = root.appending(path: "served")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        let payload = served.appending(path: "mac.ipsw")
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: payload)
        let sha = try shasum(payload)

        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let url = server.url(for: "mac.ipsw")
        let depot = Depot(directory: root.appending(path: "depot"))

        // Unpinned: the computed hash is trusted and recorded.
        let fetched = try await depot.fetch(url, expectedSHA256: nil) { _, _ in }
        #expect(fetched.sha256 == sha)
        #expect(fetched.file == depot.file(sha256: sha))
        let index = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: depot.directory.appending(path: "index.json")))
        #expect(index == [url.absoluteString: sha])
        #expect(try FileManager.default.contentsOfDirectory(atPath: depot.directory.path).sorted() == ["\(sha).ipsw", "index.json"])

        // Cached: served from the index with the server gone.
        server.stop()
        #expect(try await depot.fetch(url, expectedSHA256: nil) { _, _ in }.file == fetched.file)
    }

    @Test func rejectsWrongHashAndHTTPErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hobo-depot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let served = root.appending(path: "served")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try Data("not an ipsw".utf8).write(to: served.appending(path: "mac.ipsw"))
        let server = try HTTPServer(directory: served)
        defer { server.stop() }
        let depot = Depot(directory: root.appending(path: "depot"))
        let wrong = String(repeating: "0", count: 64)

        await #expect(throws: DepotError.self) {
            try await depot.fetch(server.url(for: "mac.ipsw"), expectedSHA256: wrong) { _, _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: depot.directory.path).isEmpty)
        await #expect(throws: DepotError.httpStatus(server.url(for: "missing.ipsw").absoluteString, 404)) {
            try await depot.fetch(server.url(for: "missing.ipsw"), expectedSHA256: nil) { _, _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: depot.directory.path).isEmpty)
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

@Suite struct BoxMetadataTests {
    @Test func encodesSnakeCaseKeys() throws {
        let metadata = BoxMetadata(
            name: "greg/macos-27", version: "1.0.0", description: nil, guestOSVersion: "27.1.0 (26A1)",
            cpus: 4, memory: "8GB", disk: "80GB", contentSHA256: "c", recipeSHA256: "r"
        )
        let json = try JSONSerialization.jsonObject(with: metadata.encoded()) as? [String: Any]
        #expect(json?["provider"] as? String == "hobo")
        #expect(json?["guest_os"] as? String == "macos")
        #expect(json?["guest_os_version"] as? String == "27.1.0 (26A1)")
        #expect(json?["min_host"] as? String == "27.0")
        #expect(json?["content_sha256"] as? String == "c")
        #expect(try JSONDecoder().decode(BoxMetadata.self, from: metadata.encoded()) == metadata)
    }

    @Test func contentHashCoversEveryFileInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appending(path: "a"), b = directory.appending(path: "b"), ab = directory.appending(path: "ab")
        try Data("disk".utf8).write(to: a)
        try Data("aux".utf8).write(to: b)
        try Data("diskaux".utf8).write(to: ab)

        // One stream over the files, so it equals the hash of their concatenation.
        #expect(try BoxMetadata.contentHash(of: [a, b]) == Depot.sha256(of: ab))
        #expect(try BoxMetadata.contentHash(of: [a, b]) != BoxMetadata.contentHash(of: [b, a]))
        #expect(throws: (any Error).self) { try BoxMetadata.contentHash(of: [a, directory.appending(path: "missing")]) }
    }

    @Test(arguments: [(UInt64(8) << 30, "8GB"), (1536 << 20, "1536MB"), (1 << 40, "1TB"), (100, "100B")])
    func byteSizesRoundTrip(bytes: UInt64, text: String) throws {
        #expect(ByteSize(bytes: bytes).description == text)
        #expect(try ByteSize(parsing: text).bytes == bytes)
    }

    @Test func checkpointKeyTracksEverythingThatShapesTheDisk() {
        let base = Checkpoint.key(ipswSHA256: "a", diskBytes: 1, conventions: "x")
        #expect(base.count == 16)
        #expect(base == Checkpoint.key(ipswSHA256: "a", diskBytes: 1, conventions: "x"))
        #expect(base != Checkpoint.key(ipswSHA256: "b", diskBytes: 1, conventions: "x"))
        #expect(base != Checkpoint.key(ipswSHA256: "a", diskBytes: 2, conventions: "x"))
        #expect(base != Checkpoint.key(ipswSHA256: "a", diskBytes: 1, conventions: "y"))
        #expect(Checkpoint.key(ipswSHA256: "a", diskBytes: 1)
            == Checkpoint.key(ipswSHA256: "a", diskBytes: 1, conventions: Conventions.fingerprint))
    }
}

@Suite struct ConventionsTests {
    @Test func embeddedPrivateKeyMatchesFirstPublicKey() throws {
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
        #expect(keyBody(derived) == keyBody(Conventions.insecurePublicKeys[0]))
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
