import Foundation
import Testing
@testable import HoboVM

/// Attaching real (tiny) disk images, which needs no entitlement, so it runs without HOBO_INTEGRATION.
/// One at a time, since `ejectAttached` lets go of everything this process attached.
@Suite(.serialized) struct WindowsInstallMediaTests {
    /// An image holding `files`, by path, with one volume.
    private func withImage(files: [String: Data] = [:], _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-media-test-\(UUID().uuidString)")
        let contents = directory.appending(path: "contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (path, data) in files { try write(data, to: contents.appending(path: path)) }
        let image = directory.appending(path: "test.dmg")
        try runQuietly("/usr/bin/hdiutil", [
            "create", "-quiet", "-srcfolder", contents.path, "-size", "5m", "-fs", "ExFAT", "-format", "UDRW",
            "-volname", "HOBO\(UUID().uuidString.prefix(6))", image.path,
        ])
        try body(image)
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    /// What `checkResult` of `files` says went wrong, or nil if it says nothing did.
    private func failure(ofMediaHolding files: [String: Data]) throws -> String? {
        var failure: String?
        try withImage(files: files) { image in
            do {
                try WindowsInstallMedia.checkResult(of: image)
            } catch let error as VMError {
                failure = error.description
            }
        }
        return failure
    }

    /// A second attach of an image gets the same disk, so without taking turns its eject pulls the
    /// volume from under the first: one create from an ISO another create is still copying.
    @Test func anAttachedImageOutlastsAnotherUseOfIt() throws {
        try withImage { image in
            let other = DispatchGroup()
            try WindowsInstallMedia.withAttached(image) { volumes in
                let volume = try #require(volumes.first)
                other.enter()
                DispatchQueue.global().async {
                    try? WindowsInstallMedia.withAttached(image) { _ in }
                    other.leave()
                }
                Thread.sleep(forTimeInterval: 2)
                #expect(FileManager.default.fileExists(atPath: volume.path))
            }
            other.wait()
        }
    }

    @Test func anInterruptedCreateLetsGoOfWhatItAttached() throws {
        try withImage { image in
            try WindowsInstallMedia.withAttached(image) { volumes in
                let volume = try #require(volumes.first)
                WindowsInstallMedia.ejectAttached()
                #expect(!FileManager.default.fileExists(atPath: volume.path))
            }
        }
    }

    // MARK: Telling an installer from anything else

    @Test(arguments: [
        (["sources/install.wim", "efi/boot/bootaa64.efi"], true),
        (["sources/install.esd", "efi/boot/bootaa64.efi"], true),
        (["efi/boot/bootaa64.efi"], false),
        // An x64 installer has its own boot file, and no Arm one.
        (["sources/install.wim", "efi/boot/bootx64.efi"], false),
    ])
    func anInstallerHasAnImageAndAnArmBootFile(_ files: [String], _ expected: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hobo-iso-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for file in files { try write(Data(), to: root.appending(path: file)) }
        #expect(WindowsInstallMedia.isInstaller(root: root) == expected)
    }

    @Test func validateAcceptsAnInstallerImage() throws {
        try withImage(files: ["sources/install.wim": Data(), "efi/boot/bootaa64.efi": Data()]) { image in
            try WindowsInstallMedia.validate(image)
        }
    }

    @Test func validateRefusesAnyOtherImage() throws {
        try withImage { image in
            #expect {
                try WindowsInstallMedia.validate(image)
            } throws: { error in
                (error as? VMError)?.description.contains("isn't a Windows on Arm installer") == true
            }
        }
    }

    // MARK: What install.cmd reported

    @Test func aResultOfOKIsSuccessWhateverItsLineEnding() throws {
        #expect(try failure(ofMediaHolding: ["hobo/result": Data("OK\r\n".utf8)]) == nil)
    }

    @Test func anyOtherResultFailsWithTheEndOfTheLog() throws {
        let log = (1...50).map { "line \($0)" }.joined(separator: "\r\n")
        let message = try #require(try failure(ofMediaHolding: ["hobo/result": Data("FAILED\r\n".utf8), "hobo/install.log": Data(log.utf8)]))
        #expect(message == "installing Windows failed: " + (11...50).map { "line \($0)" }.joined(separator: "\n"))
    }

    /// Windows writes it in a code page, which isn't always valid UTF-8.
    @Test func aLogInTheGuestsCodePageStillReads() throws {
        let message = try failure(ofMediaHolding: ["hobo/install.log": Data([0x63, 0x61, 0x66, 0xE9])])
        #expect(message == "installing Windows failed: café")
    }

    @Test func noResultAndNoLogSaysSo() throws {
        let message = try failure(ofMediaHolding: ["hobo/other": Data()])
        #expect(message == "installing Windows failed: no log was written")
    }

    @Test func mediaInstallCmdNeverReachedSaysSo() throws {
        let message = try failure(ofMediaHolding: [:])
        #expect(message == "installing Windows failed: its media has no results")
    }

    // MARK: What goes on the media

    @Test(arguments: [("a\nb", "a\r\nb"), ("a\r\nb\n", "a\r\nb\r\n"), ("", ""), ("a", "a")])
    func scriptsGetCRLFWithoutDoublingWhatTheyHave(_ text: String, _ expected: String) {
        #expect(WindowsInstallMedia.crlf(text) == expected)
    }

    @Test func theAnswerFileIsWellFormedWithThisVMsValues() throws {
        let answerFile = try WindowsInstallMedia.answerFile(computerName: "dev-box", timeZone: "Pacific Standard Time")
        #expect(XMLParser(data: Data(answerFile.utf8)).parse())
        #expect(answerFile.contains("<ComputerName>dev-box</ComputerName>"))
        #expect(answerFile.contains("<TimeZone>Pacific Standard Time</TimeZone>"))
        #expect(!answerFile.contains("@@"))
    }

    @Test(arguments: [
        ("America/Vancouver", "Pacific Standard Time"),
        ("Asia/Tokyo", "Tokyo Standard Time"),
        ("Not/AZone", "UTC"),
    ])
    func aHostTimeZoneGetsItsWindowsName(_ identifier: String, _ expected: String) {
        #expect(WindowsInstallMedia.hostTimeZone(identifier: identifier) == expected)
    }
}
