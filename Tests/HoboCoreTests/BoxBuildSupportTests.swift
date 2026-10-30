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

    @Test(arguments: [(UInt64(8) << 30, "8GB"), (1536 << 20, "1536MB"), (1 << 40, "1TB"), (100, "100B")])
    func byteSizesRoundTrip(bytes: UInt64, text: String) throws {
        #expect(ByteSize(bytes: bytes).description == text)
        #expect(try ByteSize(parsing: text).bytes == bytes)
    }

    @Test func checkpointKeyTracksEverythingThatShapesTheDisk() {
        let base = Checkpoint.key(ipswSHA256: "a", diskBytes: 1, conventionsVersion: 1)
        #expect(base.count == 16)
        #expect(base == Checkpoint.key(ipswSHA256: "a", diskBytes: 1, conventionsVersion: 1))
        #expect(base != Checkpoint.key(ipswSHA256: "b", diskBytes: 1, conventionsVersion: 1))
        #expect(base != Checkpoint.key(ipswSHA256: "a", diskBytes: 2, conventionsVersion: 1))
        #expect(base != Checkpoint.key(ipswSHA256: "a", diskBytes: 1, conventionsVersion: 2))
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
