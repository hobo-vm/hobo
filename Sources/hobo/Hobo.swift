import ArgumentParser
import Foundation
import HoboCore
import HoboVM

@main
struct HoboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hobo",
        abstract: "Vagrant-style VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [Init.self, Validate.self, Box.self]
    )
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a starter Boxcar in the current directory.")

    @Argument(help: "Box to use, e.g. greg/macos-27.")
    var box: String = "greg/macos-27"

    @Flag(help: "Overwrite an existing Boxcar.")
    var force = false

    func run() throws {
        let url = URL.currentDirectory().appending(path: Boxcar.fileName)
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw ValidationError("\(Boxcar.fileName) already exists (use --force to overwrite)")
        }
        try BoxcarTemplate.render(box: box).write(to: url, atomically: true, encoding: .utf8)
        print("Wrote \(Boxcar.fileName)")
    }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Parse the Boxcar and list its machines.")

    func run() throws {
        let boxcar = try Boxcar.load(from: .currentDirectory())
        for machine in boxcar.machines {
            let settings = boxcar.resolved(machine)
            print("\(machine.name)\t\(settings.box ?? "(no box)")")
        }
    }
}

struct Box: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build and manage boxes.",
        subcommands: [Build.self, ValidateRecipe.self]
    )

    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Build a .box from a recipe.")

        @Argument(help: "Recipe file, e.g. Recipes/macos-27.toml.")
        var recipe: String

        @Option(help: "Directory to write the .box into.")
        var output: String = "."

        @Flag(help: "Reinstall from the IPSW instead of reusing the install checkpoint.")
        var fresh = false

        @Flag(help: "On failure, keep the VM running for SSH until interrupted.")
        var holdOnFailure = false

        @MainActor
        func run() async throws {
            let options = BoxBuilder.Options(
                output: URL(filePath: output, directoryHint: .isDirectory), fresh: fresh, holdOnFailure: holdOnFailure
            )
            let builder = try BoxBuilder(recipeFile: URL(filePath: recipe), options: options) { print($0) }
            let result = try await builder.build()
            print("Built \(result.box.path)")
        }
    }

    struct ValidateRecipe: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check a recipe without building it.")

        @Argument(help: "Recipe file.")
        var recipe: String

        func run() throws {
            let recipe = try Recipe.load(from: URL(filePath: recipe))
            try recipe.checkFilesExist()
            if !recipe.source.isPinned {
                print("warning: source is unpinned (ipsw = \"latest\")")
            }
            print("\(recipe.name) \(recipe.version): \(recipe.provisioners.count) provision step(s) -> \(recipe.boxFileName)")
        }
    }
}
