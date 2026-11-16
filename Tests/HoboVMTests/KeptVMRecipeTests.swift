import Foundation
import HoboCore
import Testing

/// The recipes `make test-vms` builds the kept VMs from: only that slow, rare build reads them
/// otherwise, so a recipe that stopped parsing would go unnoticed until someone rebuilt a kept VM.
/// Needs no VM, so it runs without HOBO_INTEGRATION.
@Suite struct KeptVMRecipeTests {
    let recipes = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "recipes")

    @Test func macOSRecipeTurnsOnGUITesting() throws {
        let recipe = try Recipe.load(from: recipes.appending(path: "macos.toml"))
        #expect(recipe.os == .macOS)
        #expect(recipe.guiTesting != nil)
        #expect(recipe.security.sip)
    }

    @Test func linuxRecipeIsPinnedAndInstallsTheDesktop() throws {
        let recipe = try Recipe.load(from: recipes.appending(path: "linux.toml"))
        #expect(recipe.os == .linux)
        #expect(recipe.source.isPinned)
        #expect(!recipe.provisioners.isEmpty)
    }

    /// test-vms.sh appends `[source]` for the ISO HOBO_WINDOWS_ISO names.
    @Test func windowsRecipeIsWindowsOnceTestVMsAddsTheISO() throws {
        let toml = try String(contentsOf: recipes.appending(path: "windows.toml"), encoding: .utf8)
            + "\n[source]\niso    = \"/isos/win.iso\"\nsha256 = \"\(String(repeating: "a", count: 64))\"\n"
        let recipe = try Recipe.parse(toml, directory: URL(filePath: "/tmp"))
        #expect(recipe.os == .windows)
        #expect(recipe.source == .local(URL(filePath: "/isos/win.iso"), sha256: String(repeating: "a", count: 64)))
    }
}
