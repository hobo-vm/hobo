import ArgumentParser
import Foundation
import HoboCore

@main
struct HoboCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hobo",
        abstract: "Vagrant-style VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [Init.self, Validate.self]
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
