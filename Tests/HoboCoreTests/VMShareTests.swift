import Foundation
import Testing
@testable import HoboCore

@Suite struct VMShareTests {
    let cwd = URL(filePath: "/Users/me/work", directoryHint: .isDirectory)

    @Test func parsesAFolderNamedByItsBasename() throws {
        #expect(try VMShare.parse("/Users/me/src", currentDirectory: cwd) == VMShare(name: "src", path: "/Users/me/src", readOnly: false))
        #expect(try VMShare.parse("proj/", currentDirectory: cwd) == VMShare(name: "proj", path: "/Users/me/work/proj", readOnly: false))
        #expect(try VMShare.parse("../docs:ro", currentDirectory: cwd) == VMShare(name: "docs", path: "/Users/me/docs", readOnly: true))
    }

    @Test func argumentRoundTrips() throws {
        for argument in ["/a/b", "/a/b:ro"] {
            #expect(try VMShare.parse(argument, currentDirectory: cwd).argument == argument)
        }
    }

    @Test func refusesNothingAndTheRoot() {
        #expect(throws: VMShareError.emptyPath) { try VMShare.parse(":ro", currentDirectory: cwd) }
        #expect(throws: VMShareError.emptyPath) { try VMShare.parse("", currentDirectory: cwd) }
        #expect(throws: VMShareError.unusable("/", VMShare.volumeRootProblem)) { try VMShare.parse("/", currentDirectory: cwd) }
    }

    @Test func unshareTakesANameOrAPath() {
        let share = VMShare(name: "src", path: "/Users/me/work/src", readOnly: false)
        #expect(share.matches(VMShare.unshareTarget("SRC", currentDirectory: cwd)))
        #expect(share.matches(VMShare.unshareTarget("./src", currentDirectory: cwd)))
        #expect(share.matches(VMShare.unshareTarget("/Users/me/work/src/", currentDirectory: cwd)))
        #expect(!share.matches(VMShare.unshareTarget("other", currentDirectory: cwd)))
    }

    @Test func namesMustBeUniqueIgnoringCase() {
        let a = VMShare(name: "src", path: "/a/src", readOnly: false)
        let b = VMShare(name: "Src", path: "/b/Src", readOnly: true)
        #expect(throws: VMShareError.duplicateName("Src", "/a/src", "/b/Src")) { try VMShare.checkUnique([a, b]) }
        #expect(throws: Never.self) { try VMShare.checkUnique([a, VMShare(name: "docs", path: "/a/docs", readOnly: false)]) }
    }

    @Test func folderProblems() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hobo-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "file")
        try Data().write(to: file)

        #expect(VMShare(name: "d", path: dir.path, readOnly: false).folderProblem == nil)
        #expect(VMShare(name: "f", path: file.path, readOnly: false).folderProblem == "it is not a folder")
        #expect(VMShare(name: "m", path: dir.appending(path: "missing").path, readOnly: false).folderProblem == "it doesn't exist")
        #expect(VMShare(name: "v", path: "/System/Volumes/Data", readOnly: false).folderProblem == VMShare.volumeRootProblem)
    }
}
