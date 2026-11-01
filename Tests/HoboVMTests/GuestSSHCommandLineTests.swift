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
