import ArgumentParser
import Foundation
import HoboCore
import HoboVM

@main
struct HoboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hobo",
        abstract: "Named VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [Init.self, Validate.self, Create.self, List.self, Rename.self, Delete.self]
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

    @Argument(help: ArgumentHelp("Recipe file.", valueName: "recipe"))
    var path: String = Recipe.fileName

    func run() throws {
        let recipe = try Recipe.load(from: URL(filePath: path))
        try recipe.checkFilesExist()
        if !recipe.source.isPinned {
            print("warning: source is unpinned (ipsw = \"latest\")")
        }
        print("\(path): \(recipe.cpus) CPUs, \(recipe.memory) memory, \(recipe.disk) disk, \(recipe.provisioners.count) provision step(s)")
    }
}

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build a new VM from a recipe.")

    @Argument(help: "Name of the new VM.")
    var name: String

    @Argument(help: ArgumentHelp("Recipe file.", valueName: "recipe"))
    var path: String = Recipe.fileName

    @Flag(help: "If the build fails, keep the VM running for SSH until ^C, then delete it.")
    var holdOnFailure = false

    @MainActor
    func run() async throws {
        let recipeFile = URL(filePath: path)
        if !FileManager.default.fileExists(atPath: recipeFile.path) {
            let hint = path == Recipe.fileName ? " (run hobo init, or pass a recipe path)" : ""
            throw CLIError("no recipe at \(path)\(hint)")
        }
        let options = VMCreator.Options(name: name, recipeFile: recipeFile, holdOnFailure: holdOnFailure)
        let config = try await VMCreator(options: options) { print($0) }.create()
        print("Created \(name): macOS \(config.guestOSVersion), \(config.cpus) CPUs, \(ByteSize(bytes: config.memory)) memory")
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List VMs.")

    func run() {
        let store = VMStore.standard()
        let vms = store.list()
        guard !vms.isEmpty else {
            print("No VMs in \(store.directory.path).")
            return
        }
        let rows = [["NAME", "STATE", "OS", "CPUS", "MEMORY", "DISK (USED/SIZE)"]] + vms.map { vm in
            let used = fileSize(vm.allocatedBytes)
            switch vm.status {
            case .stopped(let config):
                return [vm.name, "stopped", "\(config.os.rawValue) \(config.guestOSVersion)", String(config.cpus),
                        fileSize(config.memory), "\(used) / \(fileSize(config.disk))"]
            case .building: return [vm.name, "building", "—", "—", "—", "\(used) / —"]
            case .failed: return [vm.name, "failed", "—", "—", "—", "\(used) / —"]
            case .broken: return [vm.name, "broken", "—", "—", "—", "\(used) / —"]
            }
        }
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            print(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces))
        }
    }
}

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a stopped VM.")

    @Argument(help: "Current name.")
    var old: String

    @Argument(help: "New name.")
    var new: String

    func run() throws {
        try VMStore.standard().rename(old, to: new)
        print("Renamed \(old) to \(new)")
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a VM and its bundle.")

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() throws {
        let store = VMStore.standard()
        let vm = try store.find(name)
        try store.checkNotRunning(vm)
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                throw CLIError("refusing to delete \(vm.name) without a terminal to confirm (pass --yes)")
            }
            print("Delete VM \"\(vm.name)\" (\(fileSize(vm.allocatedBytes)))? [y/N] ", terminator: "")
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                print("Not deleted.")
                return
            }
        }
        try store.delete(vm.name)
        print("Deleted \(vm.name)")
    }
}

/// Binary units, matching recipe sizes: an 8GB recipe shows as 8 GB, not 8.59 GB.
private func fileSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

/// A failure that isn't a usage mistake, so ArgumentParser prints it without the usage text.
struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
