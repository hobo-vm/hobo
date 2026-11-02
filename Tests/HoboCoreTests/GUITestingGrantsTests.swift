import Foundation
import SQLite3
import Testing
@testable import HoboCore

@Suite struct GUITestingGrantsTests {
    /// The `access` table as a macOS 27.2 guest has it (TCC schema version 37).
    static let schema = """
        CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
          auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
          policy_id INTEGER, indirect_object_identifier_type INTEGER,
          indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB, flags INTEGER,
          last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)), pid INTEGER, pid_version INTEGER,
          boot_uuid TEXT NOT NULL DEFAULT 'UNUSED',
          last_reminded INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)), one_time_reprompt_eligible INTEGER,
          reminder_count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (service, client, client_type, indirect_object_identifier));
        """

    /// A Data volume laid out like a fresh guest's: the system TCC.db, and tccd containers for
    /// root (other services keep theirs too) and the setup user.
    struct Volume {
        let root = FileManager.default.temporaryDirectory.appending(path: "hobo-tcc-\(UUID().uuidString)")
        var system: URL { root.appending(path: "Library/Application Support/com.apple.TCC/TCC.db") }
        var user: URL { container("USER").appending(path: "Data/Library/Application Support/com.apple.TCC/TCC.db") }

        func container(_ name: String) -> URL { root.appending(path: "private/var/containers/Data/ProtectedSystem/\(name)") }

        func make(userContainers: [Int] = [501]) throws {
            try GUITestingGrantsTests.makeDatabase(system)
            try addContainer("ROOT", identifier: "com.apple.tccd", uid: 0)
            try addContainer("OTHER", identifier: "com.apple.DeviceConfigurationAgent", uid: 501)
            for (index, uid) in userContainers.enumerated() {
                let name = index == 0 ? "USER" : "USER\(index)"
                try addContainer(name, identifier: "com.apple.tccd", uid: uid)
                try GUITestingGrantsTests.makeDatabase(container(name).appending(path: "Data/Library/Application Support/com.apple.TCC/TCC.db"))
            }
        }

        private func addContainer(_ name: String, identifier: String, uid: Int) throws {
            try FileManager.default.createDirectory(at: container(name), withIntermediateDirectories: true)
            let metadata: NSDictionary = ["MCMMetadataIdentifier": identifier, "MCMMetadataOwnership": ["uid": uid, "gid": 20]]
            try metadata.write(to: container(name).appending(path: ".com.apple.containermanagerd.metadata.plist"))
        }
    }

    @Test func grantsEveryClientInBothDatabases() throws {
        let volume = Volume()
        try volume.make()
        defer { try? FileManager.default.removeItem(at: volume.root) }
        // An unanswered prompt leaves a denial; the grant replaces it.
        try Self.execute(volume.user, """
            INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier)
            VALUES ('kTCCServiceAppleEvents', '/usr/libexec/sshd-keygen-wrapper', 1, 0, 9, 1, 'com.apple.systemevents')
            """)

        let clients = GUITestingGrants.clients(allow: ["com.example.Runner", "/usr/local/bin/tool"])
        try GUITestingGrants.apply(clients, dataVolume: volume.root)

        let system = try Self.rows(volume.system)
        #expect(system.count == 12)
        #expect(system.contains("kTCCServiceAccessibility|/usr/libexec/sshd-keygen-wrapper|1|2|4|UNUSED|csreq"))
        #expect(system.contains("kTCCServiceScreenCapture|com.apple.Terminal|0|2|4|UNUSED|csreq"))
        #expect(system.contains("kTCCServiceScreenCapture|/usr/local/bin/tool|1|2|4|UNUSED|-"))
        #expect(system.contains("kTCCServiceAccessibility|com.example.Runner|0|2|4|UNUSED|-"))
        let user = try Self.rows(volume.user)
        #expect(user.count == 6)
        #expect(user.contains("kTCCServiceAppleEvents|/usr/libexec/sshd-keygen-wrapper|1|2|4|com.apple.systemevents|csreq"))
        #expect(user.contains("kTCCServiceAppleEvents|/usr/local/bin/tool|1|2|4|com.apple.systemevents|-"))
        #expect(try Self.query(volume.user, "SELECT count(*) FROM access WHERE indirect_object_code_identity IS NULL") == ["0"])

        // Idempotent: a second pass replaces rather than duplicates.
        try GUITestingGrants.apply(clients, dataVolume: volume.root)
        #expect(try Self.rows(volume.system).count == 12)
    }

    /// The stored csreq is what `csreq -b` compiles and what tccd itself wrote for this client.
    @Test func requirementsCompileToTheBlobTCCStores() throws {
        let volume = Volume()
        try volume.make()
        defer { try? FileManager.default.removeItem(at: volume.root) }
        try GUITestingGrants.apply(Array(GUITestingGrants.defaultClients.prefix(1)), dataVolume: volume.root)
        let hex = try Self.query(volume.system, "SELECT hex(csreq) FROM access LIMIT 1")
        #expect(hex == ["FADE0C000000003C0000000100000006000000020000001D636F6D2E6170706C652E737368642D6B657967656E2D7772617070657200000000000003"])
    }

    @Test(arguments: [[], [501, 502]])
    func needsExactlyOneUserDatabase(_ uids: [Int]) throws {
        let volume = Volume()
        try volume.make(userContainers: uids)
        defer { try? FileManager.default.removeItem(at: volume.root) }
        #expect(throws: GUITestingError.userDatabase(uids.count)) {
            try GUITestingGrants.apply(GUITestingGrants.defaultClients, dataVolume: volume.root)
        }
    }

    /// A missing TCC.db means the guest isn't laid out as expected: fail, don't create an empty one.
    @Test func missingSystemDatabaseFailsWithoutCreatingOne() throws {
        let volume = Volume()
        try volume.make()
        defer { try? FileManager.default.removeItem(at: volume.root) }
        try FileManager.default.removeItem(at: volume.system)
        #expect {
            try GUITestingGrants.apply(GUITestingGrants.defaultClients, dataVolume: volume.root)
        } throws: { error in
            guard case .database(let path, _) = error as? GUITestingError else { return false }
            return path == volume.system.path
        }
        #expect(!FileManager.default.fileExists(atPath: volume.system.path))
    }

    /// tccd's container can exist before the first login has created the database in it.
    @Test func userContainerWithoutDatabaseCountsAsNone() throws {
        let volume = Volume()
        try volume.make()
        defer { try? FileManager.default.removeItem(at: volume.root) }
        try FileManager.default.removeItem(at: volume.user)
        #expect(throws: GUITestingError.userDatabase(0)) {
            try GUITestingGrants.apply(GUITestingGrants.defaultClients, dataVolume: volume.root)
        }
    }

    // MARK: - SQLite helpers

    static func makeDatabase(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        sqlite3_close(handle)
        try execute(url, schema)
    }

    static func execute(_ url: URL, _ sql: String) throws {
        _ = try query(url, sql)
    }

    /// Each row as `service|client|client_type|auth_value|auth_reason|indirect_object|csreq-or-dash`.
    static func rows(_ url: URL) throws -> Set<String> {
        Set(try query(url, """
            SELECT service || '|' || client || '|' || client_type || '|' || auth_value || '|' || auth_reason || '|' ||
              indirect_object_identifier || '|' || (CASE WHEN csreq IS NULL THEN '-' ELSE 'csreq' END)
            FROM access
            """))
    }

    static func query(_ url: URL, _ sql: String) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            Issue.record(Comment(rawValue: String(cString: sqlite3_errmsg(handle))))
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var results: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { results.append(String(cString: text)) }
        }
        return results
    }
}
