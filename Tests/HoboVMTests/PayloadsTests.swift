import Foundation
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

    @Test func aMissingPayloadSaysWhich() {
        #expect(throws: VMError.self) { try Payloads.data("nothing-here") }
    }
}
