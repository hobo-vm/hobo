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
            WindowsGuest.followDisplayCommand,
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

    @Test func aUTF8ScriptGetsOneByteOrderMark() {
        #expect(WindowsGuest.powerShellScript(Data("é".utf8)) == "\u{FEFF}é")
        #expect(WindowsGuest.powerShellScript(Data([0xEF, 0xBB, 0xBF] + Array("é".utf8))) == "\u{FEFF}é")
        #expect(WindowsGuest.powerShellScript(Data()) == "\u{FEFF}")
    }

    /// Windows-1252's é alone isn't valid UTF-8; PowerShell reads it rightly as it is.
    @Test(arguments: [[0xFF, 0xFE, 0x41, 0x00], [0xFE, 0xFF, 0x00, 0x41], [0x63, 0xE9]] as [[UInt8]])
    func aScriptInAnotherEncodingGoesUnchanged(_ bytes: [UInt8]) {
        #expect(WindowsGuest.powerShellScript(Data(bytes)) == nil)
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
        // Still at most 15 characters with the prefix.
        ("1234567890123456", "hobo-1234567890"),
        // Windows' letters and digits are ASCII ones, whatever Swift counts as a letter or a number.
        ("café", "caf"),
        ("١٢٣", "hobo"),
        ("---", "hobo"),
    ])
    func computerNames(_ name: String, _ expected: String) {
        #expect(WindowsGuest.computerName(for: name) == expected)
    }
}
