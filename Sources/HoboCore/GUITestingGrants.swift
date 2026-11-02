import Foundation
import Security
import SQLite3

/// The TCC grants recipe `[gui_testing]` writes so SSH sessions can drive the guest UI with SIP on.
///
/// TCC attributes a command run over SSH to `sshd-keygen-wrapper`, so that row is what makes
/// `osascript`, `screencapture` and scripts work over SSH; the other defaults cover the same tools
/// run another way. Each client gets Accessibility and Screen Recording in the system TCC.db and
/// Automation of System Events in the user's TCC.db (UI scripting goes through System Events).
///
/// The rows are written from the host into the stopped guest's mounted Data volume: inside the
/// guest the system TCC.db is SIP-protected and the user's (macOS 27: in tccd's ProtectedSystem
/// container) refuses even root with Full Disk Access. Verified on a macOS 27.2 guest (2026-11-01).
public enum GUITestingGrants {
    public struct Client: Equatable, Sendable {
        /// An absolute path or a bundle ID.
        public var identifier: String
        /// The designated requirement stored as the row's `csreq`. Apple clients get theirs;
        /// recipe clients get none, which tccd accepts, so they need not exist when granted.
        public var requirement: String?

        public var isPath: Bool { identifier.hasPrefix("/") }
    }

    public static let defaultClients: [Client] = [
        apple("/usr/libexec/sshd-keygen-wrapper", "com.apple.sshd-keygen-wrapper"),
        apple("/usr/bin/osascript", "com.apple.osascript"),
        apple("/usr/sbin/screencapture", "com.apple.screencapture"),
        apple("com.apple.Terminal", "com.apple.Terminal"),
    ]

    static let systemServices = ["kTCCServiceAccessibility", "kTCCServiceScreenCapture"]
    static let systemEvents = apple("com.apple.systemevents", "com.apple.systemevents")

    /// The defaults followed by the recipe's `allow` entries.
    public static func clients(allow: [String]) -> [Client] {
        defaultClients + allow.map { Client(identifier: $0, requirement: nil) }
    }

    /// Writes the grants into the guest Data volume mounted at `dataVolume`.
    public static func apply(_ clients: [Client], dataVolume: URL) throws {
        let system = try TCCDatabase(dataVolume.appending(path: "Library/Application Support/com.apple.TCC/TCC.db"))
        for client in clients {
            for service in systemServices { try system.grant(service, to: client) }
        }
        let userDB = try TCCDatabase(try userDatabase(in: dataVolume))
        for client in clients {
            try userDB.grant("kTCCServiceAppleEvents", to: client, controlling: systemEvents)
        }
    }

    /// The user's TCC.db: since macOS 27 it lives in tccd's container under
    /// `/private/var/containers/Data/ProtectedSystem`, found by the container's metadata. tccd
    /// creates it at the user's first login, which unattended setup's auto-login provides. The grants
    /// run before any recipe step, so the setup user is the only one (uid 501 and up are people).
    static func userDatabase(in dataVolume: URL) throws -> URL {
        let containers = dataVolume.appending(path: "private/var/containers/Data/ProtectedSystem")
        let found = ((try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? []).filter { container in
            guard let metadata = NSDictionary(contentsOf: container.appending(path: ".com.apple.containermanagerd.metadata.plist")),
                  metadata["MCMMetadataIdentifier"] as? String == "com.apple.tccd",
                  let uid = (metadata["MCMMetadataOwnership"] as? [String: Any])?["uid"] as? Int
            else { return false }
            return uid >= 501
        }
        guard found.count == 1 else { throw GUITestingError.userDatabase(found.count) }
        let database = found[0].appending(path: "Data/Library/Application Support/com.apple.TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: database.path) else { throw GUITestingError.userDatabase(0) }
        return database
    }

    /// Run over SSH (as root) in the conventions boot before it shuts down: waits up to 5 minutes for
    /// the auto-login session's tccd to open the user's TCC.db, which it creates. SSH answers well
    /// before the login finishes, so without this the build boots can end before the database exists.
    public static let waitForUserDatabaseCommand = """
        for attempt in $(seq 60); do
          lsof -c tccd 2>/dev/null | grep -q '/ProtectedSystem/.*/TCC\\.db$' && exit 0
          sleep 5
        done
        echo 'the user TCC database did not appear (did auto-login fail?)' >&2
        exit 1
        """

    /// Run over SSH in the guest: fails unless the session has Accessibility, Screen Recording and
    /// Automation of System Events. `screencapture` succeeds without the grant (it just leaves
    /// windows out), so Screen Recording is asked of CoreGraphics. Retried, since System Events
    /// may not answer until the auto-login session is up.
    public static let checkCommand = """
        for attempt in 1 2 3; do
          osascript -l JavaScript -e '
            ObjC.import("ApplicationServices")
            ObjC.bindFunction("CGPreflightScreenCaptureAccess", ["bool", []])
            if (!$.AXIsProcessTrusted()) throw new Error("Accessibility is not granted")
            if (!$.CGPreflightScreenCaptureAccess()) throw new Error("Screen Recording is not granted")
            Application("System Events").processes[0].name()
          ' >/dev/null && exit 0
          sleep 10
        done
        exit 1
        """

    private static func apple(_ identifier: String, _ signingID: String) -> Client {
        Client(identifier: identifier, requirement: "identifier \"\(signingID)\" and anchor apple")
    }
}

public enum GUITestingError: Error, Equatable, CustomStringConvertible {
    /// How many user TCC databases were found, when it isn't exactly one.
    case userDatabase(Int)
    case invalidRequirement(String)
    case database(String, String)

    public var description: String {
        switch self {
        case .userDatabase(0): "guest has no user TCC database (has the user logged in?)"
        case .userDatabase(let count): "guest has \(count) user TCC databases; expected only the setup user's"
        case .invalidRequirement(let requirement): "invalid code requirement: \(requirement)"
        case .database(let path, let message): "\(path): \(message)"
        }
    }
}

/// One TCC.db, written with the columns tccd itself fills for a granted row.
private final class TCCDatabase {
    private let path: String
    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        path = url.path
        // No create: a missing database means the guest isn't laid out as expected.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw GUITestingError.database(path, String(cString: sqlite3_errmsg(handle)))
        }
    }

    deinit { sqlite3_close(handle) }

    /// Allows `client` the service, replacing any earlier row (such as a denial from an
    /// unanswered prompt). `controlling` is the target app, for Automation (`kTCCServiceAppleEvents`).
    func grant(_ service: String, to client: GUITestingGrants.Client, controlling target: GUITestingGrants.Client? = nil) throws {
        let sql = """
            INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version,
              csreq, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags)
            VALUES (?, ?, ?, 2, 4, 1, ?, 0, ?, ?, 0)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, service, -1, transient)
        sqlite3_bind_text(statement, 2, client.identifier, -1, transient)
        sqlite3_bind_int(statement, 3, client.isPath ? 1 : 0)
        try bind(requirement: client.requirement, to: statement, at: 4)
        sqlite3_bind_text(statement, 5, target?.identifier ?? "UNUSED", -1, transient)
        try bind(requirement: target?.requirement, to: statement, at: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func bind(requirement: String?, to statement: OpaquePointer?, at index: Int32) throws {
        guard let requirement else {
            sqlite3_bind_null(statement, index)
            return
        }
        let blob = try Self.compile(requirement)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func error() -> GUITestingError { .database(path, String(cString: sqlite3_errmsg(handle))) }

    /// The binary form of a code requirement, as `csreq -b` writes it.
    static func compile(_ requirement: String) throws -> Data {
        var compiled: SecRequirement?
        var data: CFData?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled,
              SecRequirementCopyData(compiled, [], &data) == errSecSuccess, let data
        else { throw GUITestingError.invalidRequirement(requirement) }
        return data as Data
    }
}
