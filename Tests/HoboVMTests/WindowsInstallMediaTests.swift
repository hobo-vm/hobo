import Foundation
import Testing
@testable import HoboVM

/// Attaching real (tiny) disk images, which needs no entitlement, so it runs without HOBO_INTEGRATION.
/// One at a time, since `ejectAttached` lets go of everything this process attached.
@Suite(.serialized) struct WindowsInstallMediaTests {
    private func withImage(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-media-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appending(path: "test.dmg")
        try runQuietly("/usr/bin/hdiutil", ["create", "-quiet", "-size", "5m", "-fs", "ExFAT", "-volname", "HOBO\(UUID().uuidString.prefix(6))", image.path])
        try body(image)
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
}
