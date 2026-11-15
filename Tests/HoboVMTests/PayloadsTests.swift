import Foundation
import HoboUICore
import Testing
@testable import HoboVM

/// The files that used to be compiled in are all where `Payloads` reads them.
@Suite struct PayloadsTests {
    @Test(arguments: ["linux", "darwin", "windows"])
    func eachGuestsAgentIsThere(goos: String) throws {
        #expect(try Payloads.agent(goos).count > 1 << 20)
    }

    @Test func theFetchPortServesEveryNameItKnows() throws {
        for platform in ["linux-arm64", "darwin-arm64", "windows-arm64", "ui-darwin-arm64", "ui-linux-arm64", "ui-windows-arm64"] {
            #expect(try AgentFetchServer.binary(for: platform)?.isEmpty == false, "\(platform)")
        }
        #expect(try AgentFetchServer.binary(for: "plan9-arm64") == nil)
    }

    @Test func theWindowsBootFilesAndScriptsAreThere() throws {
        for name in ["framebuffer.efi", "loader.efi"] { #expect(try !Payloads.windowsBoot(name).isEmpty) }
        for name in ["install.cmd", "SetupComplete.cmd", "setup.ps1", "autounattend.xml"] { #expect(try !Payloads.windows(name).isEmpty) }
    }

    /// A key `hobo ui key` accepts that the Linux backend's uinput table lacks fails only in a guest.
    @Test func theLinuxBackendHasAKeyForEveryNameHoboUIAccepts() throws {
        let source = String(decoding: try Payloads.uiBackend("linux"), as: UTF8.self)
        let start = try #require(source.range(of: "\nKEYS = "))
        let end = try #require(source.range(of: "\nMODIFIERS = ", range: start.upperBound..<source.endIndex))
        let table = String(source[start.lowerBound..<end.lowerBound])
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", "import json, sys\nexec(sys.stdin.read())\nprint(json.dumps(sorted(KEYS)))"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(table.utf8))
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let keys = Set(try JSONDecoder().decode([String].self, from: printed))
        #expect(KeySpec.names.subtracting(keys).isEmpty, "missing \(KeySpec.names.subtracting(keys).sorted())")
    }

    @Test func aMissingPayloadSaysWhich() {
        #expect(throws: VMError.self) { try Payloads.data("nothing-here") }
    }
}
