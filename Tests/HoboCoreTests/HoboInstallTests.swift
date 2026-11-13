import Foundation
import Testing
@testable import HoboCore

@Suite struct HoboInstallTests {
    /// A prefix laid out as `make install` and Homebrew lay hobo out, in a temporary directory.
    func prefix(withShare: Bool) throws -> URL {
        let prefix = FileManager.default.temporaryDirectory.appending(path: "hobo-install-\(UUID().uuidString)/Cellar/hobo/1.0")
        try FileManager.default.createDirectory(at: prefix.appending(path: "bin"), withIntermediateDirectories: true)
        if withShare { try FileManager.default.createDirectory(at: prefix.appending(path: "share/hobo"), withIntermediateDirectories: true) }
        return prefix
    }

    @Test func anInstalledBinaryReadsTheShareBesideItsBin() throws {
        let prefix = try prefix(withShare: true)
        defer { try? FileManager.default.removeItem(at: prefix.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let resources = HoboInstall.resources(of: prefix.appending(path: "bin/hobo"))
        #expect(resources?.standardizedFileURL.path == prefix.appending(path: "share/hobo").standardizedFileURL.path)
    }

    @Test func aBinWithoutAShareFallsBack() throws {
        let prefix = try prefix(withShare: false)
        defer { try? FileManager.default.removeItem(at: prefix.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(HoboInstall.resources(of: prefix.appending(path: "bin/hobo")) == nil)
    }

    @Test func aBareBuildFallsBack() {
        #expect(HoboInstall.resources(of: URL(filePath: "/src/hobo/.build/debug/hobo")) == nil)
    }
}
