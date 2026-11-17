import Foundation
import Testing
@testable import HoboCore

@Suite struct SeededSetupTests {
    /// A Data volume with what `apply` touches in a freshly installed guest.
    struct Volume {
        let root = FileManager.default.temporaryDirectory.appending(path: "hobo-seed-\(UUID().uuidString)")
        var daemon: URL { root.appending(path: "Library/LaunchDaemons/com.hobo.setup.plist") }

        func make(placeholders: [String: Data]) throws {
            for directory in ["Library/LaunchDaemons", "private/etc", "private/var/db"] {
                try FileManager.default.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
            }
            for (name, contents) in placeholders {
                try contents.write(to: root.appending(path: "private/etc/\(name)"))
            }
        }

        func inode(_ path: String) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: root.appending(path: path).path)[.systemFileNumber] as? Int)
        }
    }

    @Test func turnsAPlaceholderIntoTheDaemonAndMarksSetupDone() throws {
        let volume = Volume()
        try volume.make(placeholders: ["find.codes": Data(), "rmtab": Data()])
        defer { try? FileManager.default.removeItem(at: volume.root) }
        let inode = try volume.inode("private/etc/find.codes")

        try SeededSetup.apply(dataVolume: volume.root)

        // The same file, so the owner it has in the guest (root) comes with it.
        #expect(try volume.inode("Library/LaunchDaemons/com.hobo.setup.plist") == inode)
        #expect(!FileManager.default.fileExists(atPath: volume.root.appending(path: "private/etc/find.codes").path))
        #expect(FileManager.default.fileExists(atPath: volume.root.appending(path: "private/etc/rmtab").path))
        #expect(FileManager.default.fileExists(atPath: volume.root.appending(path: "private/var/db/.AppleSetupDone").path))
        let plist = try #require(NSDictionary(contentsOf: volume.daemon) as? [String: Any])
        #expect(plist["Label"] as? String == "com.hobo.setup")
        #expect(plist["RunAtLoad"] as? Bool == true)
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.dropLast() == ["/bin/sh", "-c"])
        #expect(arguments.last == SeededSetup.script(placeholder: "/private/etc/find.codes"))
    }

    @Test func skipsAPlaceholderThatIsNotEmptyOrIsWritableByOthers() throws {
        let volume = Volume()
        try volume.make(placeholders: ["find.codes": Data("x".utf8), "kern_loader.conf": Data(), "rmtab": Data()])
        defer { try? FileManager.default.removeItem(at: volume.root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: volume.root.appending(path: "private/etc/kern_loader.conf").path)
        let inode = try volume.inode("private/etc/rmtab")

        try SeededSetup.apply(dataVolume: volume.root)

        #expect(try volume.inode("Library/LaunchDaemons/com.hobo.setup.plist") == inode)
        #expect(try Data(contentsOf: volume.root.appending(path: "private/etc/find.codes")) == Data("x".utf8))
    }

    @Test func failsWithoutAPlaceholderAndLeavesSetupAssistantOn() throws {
        let volume = Volume()
        try volume.make(placeholders: [:])
        defer { try? FileManager.default.removeItem(at: volume.root) }
        #expect(throws: SeededSetupError.noPlaceholder) { try SeededSetup.apply(dataVolume: volume.root) }
        #expect(!FileManager.default.fileExists(atPath: volume.root.appending(path: "private/var/db/.AppleSetupDone").path))
    }

    @Test func theScriptPutsThePlaceholderBackBeforeSSHAnswers() throws {
        let script = SeededSetup.script(placeholder: "/private/etc/rmtab")
        let restore = try #require(script.range(of: "mv /Library/LaunchDaemons/com.hobo.setup.plist /private/etc/rmtab"))
        let remoteLogin = try #require(script.range(of: "launchctl enable system/com.openssh.sshd"))
        #expect(restore.upperBound < remoteLogin.lowerBound)
        #expect(script.contains("sysadminctl -addUser hobo -fullName 'Hobo' -password 'hobo' -admin"))
        // kcpassword("hobo"), as printf takes it.
        #expect(script.contains(#"printf '\025\346\060\114\322\274\335\352\243\271\037\175' > /etc/kcpassword"#))
    }

    @Test func kcpasswordPadsToTwelveBytes() {
        #expect(SeededSetup.kcpassword("hobo") == [0x15, 0xE6, 0x30, 0x4C, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F, 0x7D])
        #expect(SeededSetup.kcpassword("twelve chars").count == 12)
        #expect(SeededSetup.kcpassword("thirteen char").count == 24)
    }

    @Test func onlyGuestsOlderThan27NeedIt() {
        #expect(SeededSetup.isNeeded(guestMajor: 15) && SeededSetup.isNeeded(guestMajor: 26))
        #expect(!SeededSetup.isNeeded(guestMajor: 27))
    }
}
