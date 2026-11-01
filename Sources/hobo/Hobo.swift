import ArgumentParser
import Foundation
import HoboCore

@main
struct HoboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hobo",
        abstract: "Named VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [Init.self, Validate.self]
    )
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a starter \(Recipe.fileName) in the current directory.")

    @Flag(help: "Overwrite an existing \(Recipe.fileName).")
    var force = false

    func run() throws {
        let url = URL.currentDirectory().appending(path: Recipe.fileName)
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw ValidationError("\(Recipe.fileName) already exists (use --force to overwrite)")
        }
        try Recipe.template.write(to: url, atomically: true, encoding: .utf8)
        print("Wrote \(Recipe.fileName)")
    }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check a recipe without building it.")

    @Argument(help: "Recipe file.")
    var recipe: String = Recipe.fileName

    func run() throws {
        let recipe = try Recipe.load(from: URL(filePath: recipe))
        try recipe.checkFilesExist()
        if !recipe.source.isPinned {
            print("warning: source is unpinned (ipsw = \"latest\")")
        }
        print("\(self.recipe): \(recipe.cpus) CPUs, \(recipe.memory) memory, \(recipe.disk) disk, \(recipe.provisioners.count) provision step(s)")
    }
}
