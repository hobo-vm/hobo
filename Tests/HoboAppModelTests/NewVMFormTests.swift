import Foundation
import Testing
@testable import HoboAppModel
import HoboCore

@Suite struct NewVMFormTests {
    @Test func theMachineStartsAtEachOSsDefaults() {
        var form = NewVMForm()
        #expect((form.cpus, form.memoryGB, form.diskGB) == (4, 8, 80))
        form.guiTesting = true
        form.os = .linux
        #expect((form.cpus, form.memoryGB, form.diskGB) == (4, 4, 32))
        #expect(!form.guiTesting)
        form.os = .windows
        #expect((form.memoryGB, form.diskGB) == (8, 64))
    }

    @Test func itNeedsANameAndASource() {
        var form = NewVMForm()
        #expect(form.problem == "Name the VM.")
        form.name = "bad name"
        #expect(form.problem != nil)
        form.name = "dev"
        #expect(form.problem == nil)
        form.os = .linux
        #expect(form.problem == "Pick an Ubuntu version.")
        form.os = .windows
        #expect(form.problem == "Choose a Windows on Arm installer ISO.")
        form.windowsISO = URL(filePath: "/tmp/win.iso")
        #expect(form.problem == nil)
        form.name = ""
        #expect(throws: NewVMFormError(description: "Name the VM.")) { try form.draft() }
    }

    @Test func theRecipeItWritesIsTheFormsMachine() throws {
        var form = NewVMForm()
        form.name = "dev"
        form.cpus = 6
        form.memoryGB = 12
        form.diskGB = 100
        form.guiTesting = true
        let file = try NewVMForm.writeRecipe(try form.draft())
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == Recipe.fileName)
        let recipe = try Recipe.load(from: file)
        #expect(recipe.os == .macOS && !recipe.source.isPinned)
        #expect(recipe.cpus == 6 && recipe.memory.bytes == 12 << 30 && recipe.disk.bytes == 100 << 30)
        #expect(recipe.guiTesting != nil)
    }

    @Test func aWindowsRecipePinsTheISO() throws {
        var form = NewVMForm()
        form.name = "win"
        form.os = .windows
        form.windowsISO = URL(filePath: "/tmp/Win11 \"Arm\".iso")
        let text = try form.draft(windowsSHA256: String(repeating: "c", count: 64)).text()
        let recipe = try Recipe.parse(text, directory: URL(filePath: "/tmp"))
        #expect(recipe.os == .windows && recipe.memory.bytes == 8 << 30 && recipe.disk.bytes == 64 << 30)
        #expect(text.contains(#"iso    = "/tmp/Win11 \"Arm\".iso""#))
    }
}
