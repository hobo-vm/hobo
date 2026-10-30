import Foundation
import HoboCore
import HoboVM
import Testing

/// Integration tests boot real VMs and only run with HOBO_INTEGRATION=1 (`make integration-test`).
/// The test runner can't carry the virtualization entitlement, so they drive the signed `hobo`
/// binary named by HOBO_BIN.
let environment = ProcessInfo.processInfo.environment
let integrationEnabled = environment["HOBO_INTEGRATION"] == "1"

@Suite(.enabled(if: integrationEnabled), .serialized) struct HoboVMIntegrationTests {
    /// Builds a box from the local IPSW in HOBO_TEST_IPSW. The recipe's step asserts the Vagrant
    /// conventions from inside the guest, so a box that builds has them.
    @Test(.enabled(if: environment["HOBO_TEST_IPSW"] != nil), .timeLimit(.minutes(90)))
    func boxBuildProducesConventionalBox() throws {
        let ipsw = URL(filePath: try #require(environment["HOBO_TEST_IPSW"]))
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let recipe = work.appending(path: "test.toml")
        try """
        name = "hobo/integration"
        version = "0.0.1"
        disk = "64GB"

        [source]
        ipsw = "\(ipsw.path)"
        sha256 = "\(try Depot.sha256(of: ipsw))"

        [[provision]]
        type = "shell"
        privileged = false
        inline = '''
        set -eu
        sudo -n true
        grep -q 'vagrant insecure public key' ~/.ssh/authorized_keys
        test "$(pmset -g | awk '$1 == "sleep" { print $2 }')" = 0
        '''
        """.write(to: recipe, atomically: true, encoding: .utf8)

        #expect(try run(hobo, ["box", "build", recipe.path, "--output", work.path]) == 0)

        let box = work.appending(path: "hobo-integration-0.0.1.box")
        let listing = try output("/usr/bin/tar", ["-tf", box.path])
        #expect(Set(listing.split(separator: "\n").map(String.init)) == Set([BoxMetadata.fileName] + MacVMBundle.platformFiles))
        let metadata = try JSONDecoder().decode(
            BoxMetadata.self, from: Data(output("/usr/bin/tar", ["-xOf", box.path, "metadata.json"]).utf8)
        )
        #expect(metadata.name == "hobo/integration")
        #expect(metadata.guestOSVersion.hasPrefix("27."))
        let checksum = try String(contentsOf: box.appendingPathExtension("sha256"), encoding: .utf8)
        #expect(checksum.hasPrefix(try Depot.sha256(of: box)))
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
