import Foundation
import Testing
@testable import HoboVM

/// `hobo ssh --print` prints a line meant to be pasted into the host's shell. Needs no VM.
@Suite struct GuestSSHCommandLineTests {
    let ssh = GuestSSH(host: "192.168.64.2", auth: .key(URL(filePath: "/Users/me/My Keys/id")))

    @Test func quotesArgumentsTheShellWouldChange() {
        let line = ssh.commandLine(["echo", "a;b", "$HOME", "", "it's"])
        #expect(line.hasSuffix(#" vagrant@192.168.64.2 -- echo 'a;b' '$HOME' '' 'it'\''s'"#))
        #expect(line.contains(" -i '/Users/me/My Keys/id' "))
        #expect(line.contains(" -o StrictHostKeyChecking=no "))
    }
}

@Suite struct ResumeClockTests {
    /// macOS `date`'s `mmddHHMMccyy.ss`, in UTC whatever the host's time zone.
    @Test func macSetClockCommandUsesUTC() {
        let date = Date(timeIntervalSince1970: 1_800_000_007) // 2027-01-15 08:00:07 UTC
        #expect(MacVMBundle.setClockCommand(date) == "sudo -n date -u 011508002027.07 >/dev/null")
    }

    /// Epoch seconds: uutils `date` (Ubuntu 26.04) rejects the macOS form.
    @Test func linuxSetClockCommandUsesEpochSeconds() {
        let date = Date(timeIntervalSince1970: 1_800_000_007.25)
        #expect(LinuxVMBundle.setClockCommand(date) == "sudo -n date -u -s @1800000007.250 >/dev/null")
    }
}
