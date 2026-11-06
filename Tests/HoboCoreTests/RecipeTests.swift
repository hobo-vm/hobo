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

    @Test func missingFileIsNotFoundWithTheGivenPath() {
        #expect(throws: RecipeError.notFound("no/such.toml")) { try Recipe.load(from: URL(filePath: "no/such.toml")) }
        #expect(RecipeError.notFound("x.toml").description == "no recipe at x.toml")
        #expect(RecipeError.notFound(Recipe.fileName).description.hasSuffix("(run hobo init, or pass a recipe path)"))
    }

    @Test func summaryReportsSourceAndBytes() throws {
        let latest = RecipeSummary(try Recipe.parse(minimal(source: #"ipsw = "latest""#), directory: directory), path: "Hobo.toml")
        #expect(latest.source == "latest" && !latest.pinned)
        #expect(latest.memory == Recipe.defaultMemory(for: .macOS).bytes && latest.provisionSteps == 0)
        #expect(latest.os == .macOS)
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
        #expect(recipe.os == .macOS)
        #expect(recipe.cpus == Recipe.defaultCPUs)
        #expect(recipe.memory == ByteSize(bytes: 8 << 30))
        #expect(recipe.disk == ByteSize(bytes: 80 << 30))
    }

    @Test func imageSourceIsALinuxGuestWithLinuxDefaults() throws {
        let url = "https://cloud-images.ubuntu.com/server/releases/resolute/release-20261016/ubuntu-26.04-server-cloudimg-arm64.img"
        let recipe = try Recipe.parse(minimal(source: "image = \"\(url)\"\nsha256 = \"\(sha)\""), directory: directory)
        #expect(recipe.os == .linux)
        #expect(recipe.source == .remote(URL(string: url)!, sha256: sha))
        #expect(recipe.cpus == Recipe.defaultCPUs)
        #expect(recipe.memory == ByteSize(bytes: 4 << 30))
        #expect(recipe.disk == ByteSize(bytes: 32 << 30))
        #expect(RecipeSummary(recipe, path: "x").os == .linux)

        let local = try Recipe.parse(minimal(source: "image = \"img/ubuntu.img\"\nsha256 = \"\(sha)\""), directory: directory)
        #expect(local.source == .local(URL(filePath: "/recipes/img/ubuntu.img"), sha256: sha))
    }

    @Test func imageSourceMustBePinned() {
        #expect(throws: RecipeError.missingSHA256("latest")) {
            try Recipe.parse(minimal(source: #"image = "latest""#), directory: directory)
        }
    }

    @Test func sourceNeedsExactlyOneKind() {
        #expect(throws: RecipeError.sourceKind) {
            try Recipe.parse(minimal(source: "ipsw = \"latest\"\nimage = \"x.img\"\nsha256 = \"\(sha)\""), directory: directory)
        }
        #expect(throws: RecipeError.sourceKind) {
            try Recipe.parse(minimal(source: "sha256 = \"\(sha)\""), directory: directory)
        }
    }

    @Test(arguments: ["[security]\nsip = false", "[gui_testing]\nenabled = true"])
    func macOSOnlyTablesAreRejectedForLinux(_ table: String) {
        let recipe = minimal(source: "image = \"x.img\"\nsha256 = \"\(sha)\"") + "\n" + table
        let name = String(table.prefix { $0 != "\n" })
        #expect(throws: RecipeError.macOSOnly(name)) { try Recipe.parse(recipe, directory: directory) }
    }

    @Test(arguments: ["[security]\nsip = false", "[gui_testing]\nenabled = true"])
    func macOSOnlyTablesAreRejectedForWindows(_ table: String) {
        let recipe = minimal(source: "iso = \"x.iso\"\nsha256 = \"\(sha)\"") + "\n" + table
        let name = String(table.prefix { $0 != "\n" })
        #expect(throws: RecipeError.macOSOnly(name)) { try Recipe.parse(recipe, directory: directory) }
    }

    @Test func anISOMakesAWindowsGuest() throws {
        let recipe = try Recipe.parse("[source]\niso = \"win.iso\"\nsha256 = \"\(sha)\"", directory: directory)
        #expect(recipe.os == .windows)
        #expect(recipe.source == .local(URL(filePath: "/recipes/win.iso"), sha256: sha))
        #expect(recipe.memory.bytes == 8 << 30)
        #expect(recipe.disk.bytes == 64 << 30)
    }

    @Test func windowsHasNoLatest() {
        #expect(throws: RecipeError.self) { try Recipe.parse("[source]\niso = \"latest\"", directory: directory) }
    }

    @Test func aWindowsStepCantDropPrivileges() {
        let recipe = minimal(source: "iso = \"x.iso\"\nsha256 = \"\(sha)\"")
            + "\n[[provision]]\ntype = \"shell\"\ninline = \"exit 0\"\nprivileged = false"
        #expect(throws: RecipeError.self) { try Recipe.parse(recipe, directory: directory) }
    }

    @Test func theWindowsTemplateParses() throws {
        let recipe = try Recipe.parse(Recipe.template(windowsISO: "/isos/win.iso", sha256: sha), directory: directory)
        #expect(recipe.os == .windows)
        #expect(recipe.source == .local(URL(filePath: "/isos/win.iso"), sha256: sha))
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

    @Test func guiTestingIsOptInWithExtraClients() throws {
        let latest = minimal(source: #"ipsw = "latest""#)
        #expect(try Recipe.parse(latest, directory: directory).guiTesting == nil)
        #expect(try Recipe.parse(latest + "\n[gui_testing]\nallow = [\"com.x\"]", directory: directory).guiTesting == nil)
        let enabled = try Recipe.parse(latest + "\n[gui_testing]\nenabled = true", directory: directory)
        #expect(enabled.guiTesting == Recipe.GUITesting(allow: []))
        #expect(RecipeSummary(enabled, path: "x").guiTesting)
        let allowed = try Recipe.parse(
            latest + "\n[gui_testing]\nenabled = true\nallow = [\"com.example.AppUITests.xctrunner\", \"/usr/local/bin/tool\"]",
            directory: directory
        )
        #expect(allowed.guiTesting?.allow == ["com.example.AppUITests.xctrunner", "/usr/local/bin/tool"])
    }

    @Test func securityDefaultsOnAndCanBeTurnedOff() throws {
        let latest = minimal(source: #"ipsw = "latest""#)
        #expect(try Recipe.parse(latest, directory: directory).security == Recipe.Security())
        let sipOff = try Recipe.parse(latest + "\n[security]\nsip = false", directory: directory)
        #expect(sipOff.security == Recipe.Security(sip: false, amfi: true))
        let bothOff = try Recipe.parse(latest + "\n[security]\nsip = false\namfi = false", directory: directory)
        #expect(bothOff.security == Recipe.Security(sip: false, amfi: false))
        let summary = RecipeSummary(bothOff, path: "x")
        #expect(!summary.sip && !summary.amfi)
    }

    @Test func amfiOffNeedsSIPOff() {
        #expect(throws: RecipeError.amfiNeedsSIPOff) {
            try Recipe.parse(minimal(source: #"ipsw = "latest""#) + "\n[security]\namfi = false", directory: directory)
        }
    }

    @Test(arguments: ["", "bin/tool", "com.example app"])
    func guiTestingClientsAreAbsolutePathsOrBundleIDs(_ client: String) {
        #expect(throws: RecipeError.invalidGUITestingClient(client)) {
            try Recipe.parse(minimal(source: #"ipsw = "latest""#) + "\n[gui_testing]\nenabled = true\nallow = [\"\(client)\"]", directory: directory)
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

    /// The template's commented-out steps and `[gui_testing]` are well formed once uncommented.
    @Test func initTemplateExampleStepsParse() throws {
        let uncommented = Recipe.template.replacingOccurrences(of: "# [[provision]]", with: "[[provision]]")
            .replacingOccurrences(of: "# [gui_testing]", with: "[gui_testing]")
            .replacingOccurrences(of: "# [security]", with: "[security]")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.hasPrefix("# ") && line.contains("=") && !line.contains("ipsw") ? line.dropFirst(2) : line
            }
            .joined(separator: "\n")
        let recipe = try Recipe.parse(uncommented, directory: directory)
        #expect(recipe.provisioners.map(\.type) == [.shell, .shell, .file])
        #expect(recipe.provisioners[1].privileged == false)
        #expect(recipe.guiTesting?.allow == ["com.example.AppUITests.xctrunner"])
        #expect(recipe.security == Recipe.Security(sip: false, amfi: false))
    }

    @Test func linuxInitTemplateParsesPinned() throws {
        let image = ubuntuImage
        let template = Recipe.template(pinnedTo: image, desktop: false)
        let recipe = try Recipe.parse(template, directory: directory)
        #expect(recipe.os == .linux)
        #expect(recipe.source == .remote(image.url, sha256: sha))
        #expect(recipe.memory == Recipe.defaultMemory(for: .linux) && recipe.disk == Recipe.defaultDisk(for: .linux))

        let uncommented = template.replacingOccurrences(of: "# [[provision]]", with: "[[provision]]")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.hasPrefix("# ") && line.contains(" = ") ? line.dropFirst(2) : line }
            .joined(separator: "\n")
        let steps = try Recipe.parse(uncommented, directory: directory).provisioners
        #expect(steps.map(\.type) == [.shell, .file])
        #expect(steps[1].destination == "/home/vagrant/.bashrc")
    }

    @Test func linuxDesktopTemplateStartsWithTheDesktopStep() throws {
        let image = ubuntuImage
        let recipe = try Recipe.parse(Recipe.template(pinnedTo: image, desktop: true), directory: directory)
        let step = try #require(recipe.provisioners.first)
        #expect(recipe.provisioners.count == 1)
        #expect(step.type == .shell && step.privileged != false)
        #expect(step.inline == Recipe.desktopScript)
        #expect(step.inline?.contains("AutomaticLogin=vagrant") == true)
        #expect(!Recipe.template(pinnedTo: image, desktop: false).contains("ubuntu-desktop-minimal"))
    }

    private var ubuntuImage: UbuntuCatalog.Image {
        UbuntuCatalog.Image(
            name: "Ubuntu 26.04 LTS", version: "26.04", codename: "Resolute Raccoon", lts: true, serial: "20261016",
            url: URL(string: "https://cloud-images.ubuntu.com/x/ubuntu-26.04-server-cloudimg-arm64.img")!, sha256: sha,
            size: 1, supported: true, supportEnds: nil
        )
    }

    private func minimal(source: String) -> String {
        """
        [source]
        \(source)
        """
    }
}
