import Foundation
import Testing

/// Integration tests drive the signed `hobo` binary and only run with HOBO_INTEGRATION=1
/// (`make integration-test`). The test runner can't carry the virtualization entitlement, so VM
/// tests must go through the binary named by HOBO_BIN.
let environment = ProcessInfo.processInfo.environment
let integrationEnabled = environment["HOBO_INTEGRATION"] == "1"

@Suite(.enabled(if: integrationEnabled), .serialized) struct HoboVMIntegrationTests {
    /// `hobo init` writes a recipe that `hobo validate` accepts.
    @Test func initWritesAValidRecipe() throws {
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-init-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        #expect(try run(hobo, ["init"], in: work) == 0)
        #expect(FileManager.default.fileExists(atPath: work.appending(path: "Hobo.toml").path))
        #expect(try run(hobo, ["init"], in: work) != 0, "init must not overwrite without --force")
        #expect(try run(hobo, ["validate"], in: work) == 0)
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
