import Foundation
import Testing
@testable import HoboCore

@Suite struct GuestCopyTests {
    let cwd = URL(filePath: "/work/dir", directoryHint: .isDirectory)

    @Test func copiesHostPathsIntoAGuest() throws {
        let (vm, copy) = try GuestCopy.parse(["app", "/abs/x", "dev:/tmp/"], currentDirectory: cwd)
        #expect(vm == "dev")
        #expect(copy == GuestCopy(direction: .toGuest, sources: ["/work/dir/app", "/abs/x"], destination: "/tmp/"))
        #expect(copy.scpArguments(remote: "hobo@1.2.3.4") == ["-q", "-r", "--", "/work/dir/app", "/abs/x", "hobo@1.2.3.4:/tmp/"])
    }

    @Test func copiesGuestPathsToTheHost() throws {
        let (vm, copy) = try GuestCopy.parse(["dev:a", "dev:/b c", "."], currentDirectory: cwd)
        #expect(vm == "dev")
        #expect(copy == GuestCopy(direction: .fromGuest, sources: ["a", "/b c"], destination: "/work/dir"))
        #expect(copy.scpArguments(remote: "u@h") == ["-q", "-r", "--", "u@h:a", "u@h:/b c", "/work/dir"])
    }

    @Test func keepsATrailingSlashOnAHostDestination() throws {
        let (_, copy) = try GuestCopy.parse(["dev:a", "out/"], currentDirectory: cwd)
        #expect(copy.destination == "/work/dir/out/")
    }

    @Test func aColonAfterASlashIsAHostPath() throws {
        let (_, copy) = try GuestCopy.parse(["./a:b", "dev:"], currentDirectory: cwd)
        #expect(copy.sources == ["/work/dir/a:b"])
        #expect(copy.destination == "")
    }

    @Test(arguments: [
        (["dev:a"], GuestCopyError.tooFewOperands),
        (["a", "b"], .noGuest),
        (["dev:a", "dev:b"], .guestToGuest),
        (["dev:a", "local", "out"], .mixedSources),
        (["dev:a", "other:b", "out"], .severalGuests),
    ])
    func refusesBadOperands(operands: [String], error: GuestCopyError) {
        #expect(throws: error) { try GuestCopy.parse(operands, currentDirectory: cwd) }
    }
}
