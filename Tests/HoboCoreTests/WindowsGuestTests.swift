import Foundation
import Testing
@testable import HoboCore

@Suite struct WindowsGuestTests {
    /// sshd would have to escape a double quote on its way to PowerShell, and these go that way.
    @Test func noCommandHasADoubleQuote() {
        let command = ["app.exe", #"say "hi""#, "it's"]
        for line in [
            WindowsGuest.execLine(command, marker: "m"), WindowsGuest.guiExecLine(command, marker: "m"),
            WindowsGuest.cancelCommand(pid: 7), WindowsGuest.shutdownCommand, WindowsGuest.versionCommand,
            WindowsGuest.growDiskCommand, WindowsGuest.cleanupCommand, WindowsGuest.setClockCommand(.now),
        ] {
            #expect(!line.contains("\""), "\(line)")
            #expect(!line.contains("\n"), "\(line)")
        }
    }

    @Test func aCommandTravelsAsBase64OfJSON() throws {
        let command = ["app.exe", #"say "hi""#, "it's", "ünï"]
        let line = WindowsGuest.execLine(command, marker: "MARK")
        let prefix = #"& 'C:\ProgramData\Hobo\exec.ps1' 'MARK' '"#
        let suffix = "'; exit $LASTEXITCODE"
        #expect(line.hasPrefix(prefix) && line.hasSuffix(suffix))
        let encoded = line.dropFirst(prefix.count).dropLast(suffix.count)
        let data = try #require(Data(base64Encoded: String(encoded)))
        #expect(try JSONDecoder().decode([String].self, from: data) == command)
    }

    @Test func guiExecGoesThroughItsOwnScript() {
        #expect(WindowsGuest.guiExecLine(["a"], marker: "m").hasPrefix(#"& 'C:\ProgramData\Hobo\gui-exec.ps1' 'm' "#))
    }

    @Test func cancelNamesTheProcess() {
        #expect(WindowsGuest.cancelCommand(pid: 42) == #"& 'C:\ProgramData\Hobo\cancel.ps1' '42'; exit $LASTEXITCODE"#)
    }

    @Test func theClockIsSetInDotNetTicksFromUTC() {
        // 1970-01-01 is 621355968000000000 ticks; a second is ten million more.
        let line = WindowsGuest.setClockCommand(Date(timeIntervalSince1970: 1))
        #expect(line.contains("621355968010000000, [DateTimeKind]::Utc"))
    }

    @Test(arguments: [
        ("dev", "dev"),
        ("my_app.test", "my-app-test"),
        ("a-very-long-name-for-a-vm", "a-very-long-nam"),
        // Cut at 15 characters, which would otherwise end on a hyphen.
        ("fourteen-chars-x", "fourteen-chars"),
        ("12345", "hobo-12345"),
        ("---", "hobo"),
    ])
    func computerNames(_ name: String, _ expected: String) {
        #expect(WindowsGuest.computerName(for: name) == expected)
    }
}
