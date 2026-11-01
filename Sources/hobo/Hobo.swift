import ArgumentParser
import Foundation
import HoboCore

@main
struct HoboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hobo",
        abstract: "Named VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [Init.self, Validate.self, Images.self]
    )
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a starter \(Recipe.fileName) in the current directory.")

    @Argument(help: ArgumentHelp(
        "A macOS build from `hobo images` (e.g. 26B123) to pin the source to. Without one, the source is \"latest\".",
        valueName: "build"
    ))
    var build: String?

    @Flag(help: "Overwrite an existing \(Recipe.fileName).")
    var force = false

    func run() async throws {
        let url = URL.currentDirectory().appending(path: Recipe.fileName)
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw ValidationError("\(Recipe.fileName) already exists (use --force to overwrite)")
        }
        var template = Recipe.template
        var pinned = ""
        if let build {
            let image = try IPSWCatalog.image(build: build, in: try await IPSWCatalog.fetch(), hostMajor: IPSWCatalog.hostMajor)
            template = Recipe.template(pinnedTo: image)
            pinned = " pinned to \(image.name) \(image.version) (\(image.build))"
        }
        try template.write(to: url, atomically: true, encoding: .utf8)
        print("Wrote \(Recipe.fileName)\(pinned)")
    }
}

struct Images: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the macOS IPSWs this Mac can build VMs from.",
        discussion: "Pass a BUILD to `hobo init <build>` to start a recipe pinned to it. The list comes from ipsw.me."
    )

    @Argument(help: ArgumentHelp("Show the details of this build (e.g. 26B123) instead of the list.", valueName: "build"))
    var build: String?

    @Flag(help: "Show only the newest build of each major version.")
    var latest = false

    @Flag(help: "Print the full records (URL, SHA-256, size in bytes, signed) as JSON.")
    var json = false

    func validate() throws {
        if build != nil && latest { throw ValidationError("--latest lists builds; it can't be combined with a build") }
    }

    func run() async throws {
        let catalog = try await IPSWCatalog.fetch()
        if let build {
            try show(IPSWCatalog.image(build: build, in: catalog))
            return
        }
        var images = IPSWCatalog.runnable(catalog, hostMajor: IPSWCatalog.hostMajor)
        if latest { images = IPSWCatalog.latestPerMajor(images) }
        if json {
            print(String(decoding: try IPSWCatalog.json(images), as: UTF8.self))
            return
        }
        let rows = [["NAME", "VERSION", "BUILD", "RELEASED", "SIZE"]] + images.map { image in
            [image.name, image.version, image.build, image.releasedDay, image.formattedSize]
        }
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max()! }
        for row in rows {
            print(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
    }

    private func show(_ image: IPSWCatalog.Image) throws {
        if json {
            print(String(decoding: try IPSWCatalog.json(image), as: UTF8.self))
            return
        }
        let fields = [
            ("Name", image.name), ("Version", image.version), ("Build", image.build),
            ("Released", image.releasedDay),
            ("Size", "\(image.formattedSize) (\(image.size) bytes)"), ("URL", image.url.absoluteString),
            ("SHA-256", image.sha256), ("Signed", image.signed ? "yes" : "no"),
        ]
        for (label, value) in fields {
            print(label.padding(toLength: 10, withPad: " ", startingAt: 0) + value)
        }
        if image.major > IPSWCatalog.hostMajor {
            print("\nThis Mac (macOS \(IPSWCatalog.hostMajor)) can't run it: the guest is newer than the host.")
        }
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

private extension IPSWCatalog.Image {
    var releasedDay: String { released.formatted(.iso8601.year().month().day()) }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}
