import Foundation
import Testing
@testable import HoboCore

@Suite struct RecipeTests {
    let directory = URL(filePath: "/recipes", directoryHint: .isDirectory)
    let sha = String(repeating: "ab", count: 32)

    @Test func parsesFullRecipe() throws {
        let recipe = try Recipe.parse("""
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
        #expect(recipe.resolve("files/profile").path == "/recipes/files/profile")
    }

    @Test func summaryReportsSourceAndBytes() throws {
        let latest = RecipeSummary(try Recipe.parse(minimal(source: #"ipsw = "latest""#), directory: directory), path: "Hobo.toml")
        #expect(latest.source == "latest" && !latest.pinned)
        #expect(latest.memory == Recipe.defaultMemory.bytes && latest.provisionSteps == 0)
        let local = try Recipe.parse(minimal(source: "ipsw = \"macOS.ipsw\"\nsha256 = \"\(sha)\""), directory: directory)
        #expect(RecipeSummary(local, path: "x").source == "/recipes/macOS.ipsw")
        #expect(RecipeSummary(local, path: "x").pinned)
        let remote = try Recipe.parse(minimal(source: "ipsw = \"https://example.com/mac.ipsw\"\nsha256 = \"\(sha)\""), directory: directory)
        #expect(RecipeSummary(remote, path: "x").source == "https://example.com/mac.ipsw")
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
        let dir = FileManager.default.temporaryDirectory.appending(path: "hobo-recipe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "present.sh"))

        let recipe = try Recipe.parse(minimal(source: "ipsw = \"mac.ipsw\"\nsha256 = \"\(sha)\"") + """

        [[provision]]
        type = "shell"
        path = "setup.sh"

        [[provision]]
        type = "shell"
        path = "present.sh"

        [[provision]]
        type = "shell"
        inline = "true"

        [[provision]]
        type = "file"
        source = "files/profile"
        destination = "/Users/vagrant/.profile"
        """, directory: dir)
        #expect(recipe.missingFiles() == ["setup.sh", "files/profile", dir.appending(path: "mac.ipsw").standardizedFileURL.path])
        #expect(throws: RecipeError.missingFiles(recipe.missingFiles())) { try recipe.checkFilesExist() }
    }

    @Test func initTemplateParsesAndUsesLatest() throws {
        let recipe = try Recipe.parse(Recipe.template, directory: directory)
        #expect(recipe.source == .latest)
        #expect(recipe.missingFiles().isEmpty)
        #expect(recipe.provisioners.isEmpty)
    }

    /// The template's commented-out steps are well formed once uncommented.
    @Test func initTemplateExampleStepsParse() throws {
        let uncommented = Recipe.template.replacingOccurrences(of: "# [[provision]]", with: "[[provision]]")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.hasPrefix("# ") && line.contains("=") && !line.contains("ipsw") ? line.dropFirst(2) : line
            }
            .joined(separator: "\n")
        let recipe = try Recipe.parse(uncommented, directory: directory)
        #expect(recipe.provisioners.map(\.type) == [.shell, .shell, .file])
        #expect(recipe.provisioners[1].privileged == false)
    }

    private func minimal(source: String) -> String {
        """
        [source]
        \(source)
        """
    }
}
