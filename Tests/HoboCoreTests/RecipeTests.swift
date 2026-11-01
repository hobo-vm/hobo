import Foundation
import Testing
@testable import HoboCore

@Suite struct RecipeTests {
    let directory = URL(filePath: "/recipes", directoryHint: .isDirectory)
    let sha = String(repeating: "ab", count: 32)

    @Test func parsesFullRecipe() throws {
        let recipe = try Recipe.parse("""
        name = "greg/macos-27"
        version = "1.0.0"
        description = "macOS 27 base"
        cpus = 6
        memory = "16GB"
        disk = "100GB"

        [source]
        ipsw = "https://updates.cdn-apple.com/x/UniversalMac_27.1_Restore.ipsw"
        sha256 = "\(sha.uppercased())"

        [[provision]]
        type = "shell"
        inline = "echo hi"
        privileged = false
        env = { A = "1" }

        [[provision]]
        type = "file"
        source = "files/profile"
        destination = "/Users/vagrant/.profile"
        """, directory: directory)
        #expect(recipe.cpus == 6)
        #expect(recipe.memory == ByteSize(bytes: 16 << 30))
        #expect(recipe.disk == ByteSize(bytes: 100 << 30))
        #expect(recipe.source == .remote(URL(string: "https://updates.cdn-apple.com/x/UniversalMac_27.1_Restore.ipsw")!, sha256: sha))
        #expect(recipe.provisioners.map(\.type) == [.shell, .file])
        #expect(recipe.provisioners[0].env == ["A": "1"])
        #expect(recipe.boxFileName == "greg-macos-27-1.0.0.box")
        #expect(recipe.resolve("files/profile").path == "/recipes/files/profile")
    }

    @Test func latestNeedsNoHashAndAppliesDefaults() throws {
        let recipe = try Recipe.parse(minimal(source: #"ipsw = "latest""#), directory: directory)
        #expect(recipe.source == .latest)
        #expect(!recipe.source.isPinned)
        #expect(recipe.cpus == Recipe.defaultCPUs)
        #expect(recipe.disk == Recipe.defaultDisk)
    }

    @Test func localPathResolvesAgainstRecipeDirectory() throws {
        let recipe = try Recipe.parse(minimal(source: "ipsw = \"../ipsw/mac.ipsw\"\nsha256 = \"\(sha)\""), directory: directory)
        #expect(recipe.source == .local(URL(filePath: "/ipsw/mac.ipsw"), sha256: sha))
    }

    @Test func pinnedSourcesNeedAHash() {
        #expect(throws: RecipeError.missingSHA256("mac.ipsw")) {
            try Recipe.parse(minimal(source: #"ipsw = "mac.ipsw""#), directory: directory)
        }
        #expect(throws: RecipeError.invalidSHA256("nope")) {
            try Recipe.parse(minimal(source: "ipsw = \"mac.ipsw\"\nsha256 = \"nope\""), directory: directory)
        }
    }

    @Test func guiTestingIsRejectedForNow() {
        #expect(throws: RecipeError.guiTestingNotImplemented) {
            try Recipe.parse(minimal(source: #"ipsw = "latest""#) + "\n[gui_testing]\nenabled = true", directory: directory)
        }
    }

    @Test(arguments: ["", "a/b/c", "has space", "/leading"])
    func invalidNamesAreRejected(name: String) {
        #expect(throws: RecipeError.invalidName(name)) {
            try Recipe.parse(minimal(source: #"ipsw = "latest""#, name: name), directory: directory)
        }
    }

    @Test(arguments: ["1.0/../../x", "1 0", "../.."])
    func versionsThatAreNotFileNameSafeAreRejected(version: String) {
        #expect(throws: RecipeError.invalidVersion(version)) {
            try Recipe.parse(minimal(source: #"ipsw = "latest""#, version: version), directory: directory)
        }
    }

    @Test(arguments: [
        ("cpus = 0", "cpus must be at least 1"),
        ("memory = \"0GB\"", "memory must be more than 0"),
        ("disk = \"0B\"", "disk must be more than 0"),
    ])
    func emptyHardwareIsRejected(line: String, reason: String) {
        let toml = minimal(source: #"ipsw = "latest""#).replacingOccurrences(of: "[source]", with: "\(line)\n[source]")
        #expect(throws: RecipeError.invalidHardware(reason)) {
            try Recipe.parse(toml, directory: directory)
        }
    }

    @Test func malformedStepsAreRejected() {
        #expect(throws: RecipeError.invalidProvisioner(0, "shell needs exactly one of inline or path")) {
            try Recipe.parse(minimal(source: #"ipsw = "latest""#) + "\n[[provision]]\ntype = \"shell\"", directory: directory)
        }
        #expect(throws: RecipeError.invalidProvisioner(0, "file needs source and destination")) {
            try Recipe.parse(minimal(source: #"ipsw = "latest""#) + "\n[[provision]]\ntype = \"file\"\nsource = \"x\"", directory: directory)
        }
    }

    @Test func missingFilesAreReported() throws {
        let recipe = try Recipe.parse(minimal(source: #"ipsw = "latest""#) + """

        [[provision]]
        type = "shell"
        path = "setup.sh"
        """, directory: FileManager.default.temporaryDirectory)
        #expect(recipe.missingFiles() == ["setup.sh"])
    }

    private func minimal(source: String, name: String = "greg/macos-27", version: String = "1.0.0") -> String {
        """
        name = "\(name)"
        version = "\(version)"
        [source]
        \(source)
        """
    }
}
