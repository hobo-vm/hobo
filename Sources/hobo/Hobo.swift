import AppKit
import ArgumentParser
import Foundation
import HoboControl
import HoboCore
import HoboVM

/// A synchronous entry point, because `_vm-run` must run AppKit's event loop from the top of the
/// main thread: started from inside Swift's async main, the loop never services the main actor.
@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == VMRun.configuration.commandName {
            VMRun.main(Array(arguments.dropFirst()))
        }
        Task {
            await HoboCommand.main()
            exit(0)
        }
        dispatchMain()
    }
}

struct HoboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hobo",
        abstract: "Named VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [
            Init.self, Validate.self, Images.self, Create.self, List.self, Start.self, Stop.self,
            Rename.self, Delete.self,
        ]
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

    @Flag(help: "Print the recipe's path and the image it is pinned to as JSON.")
    var json = false

    private struct Result: Encodable {
        var path: String
        var image: IPSWCatalog.Image?
    }

    func run() async throws {
        let output = Output(json: json)
        try await output.reporting {
            let url = URL.currentDirectory().appending(path: Recipe.fileName)
            if FileManager.default.fileExists(atPath: url.path) && !force {
                throw ValidationError("\(Recipe.fileName) already exists (use --force to overwrite)")
            }
            var template = Recipe.template
            var image: IPSWCatalog.Image?
            if let build {
                image = try IPSWCatalog.image(build: build, in: try await IPSWCatalog.fetch(), hostMajor: IPSWCatalog.hostMajor)
                template = Recipe.template(pinnedTo: image!)
            }
            try template.write(to: url, atomically: true, encoding: .utf8)
            let pinned = image.map { " pinned to \($0.name) \($0.version) (\($0.build))" } ?? ""
            output.result(Result(path: url.path, image: image), text: "Wrote \(Recipe.fileName)\(pinned)")
        }
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
        let output = Output(json: json)
        try await output.reporting {
            let catalog = try await IPSWCatalog.fetch()
            if let build {
                let image = try IPSWCatalog.image(build: build, in: catalog)
                output.result(image, text: details(image))
                return
            }
            var images = IPSWCatalog.runnable(catalog, hostMajor: IPSWCatalog.hostMajor)
            if latest { images = IPSWCatalog.latestPerMajor(images) }
            output.result(images, text: table(images))
        }
    }

    private func table(_ images: [IPSWCatalog.Image]) -> String {
        let rows = [["NAME", "VERSION", "BUILD", "RELEASED", "SIZE"]] + images.map { image in
            [image.name, image.version, image.build, image.releasedDay, image.formattedSize]
        }
        return formatTable(rows)
    }

    private func details(_ image: IPSWCatalog.Image) -> String {
        let fields = [
            ("Name", image.name), ("Version", image.version), ("Build", image.build),
            ("Released", image.releasedDay),
            ("Size", "\(image.formattedSize) (\(image.size) bytes)"), ("URL", image.url.absoluteString),
            ("SHA-256", image.sha256), ("Signed", image.signed ? "yes" : "no"),
        ]
        var lines = fields.map { label, value in label.padding(toLength: 10, withPad: " ", startingAt: 0) + value }
        if image.major > IPSWCatalog.hostMajor {
            lines.append("\nThis Mac (macOS \(IPSWCatalog.hostMajor)) can't run it: the guest is newer than the host.")
        }
        return lines.joined(separator: "\n")
    }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check a recipe without building it.")

    @Argument(help: ArgumentHelp("Recipe file.", valueName: "recipe"))
    var path: String = Recipe.fileName

    @Flag(help: "Print the recipe's settings as JSON.")
    var json = false

    func run() throws {
        let output = Output(json: json)
        try output.reporting {
            let recipe = try Recipe.load(from: URL(filePath: path))
            try recipe.checkFilesExist()
            let warning = recipe.source.isPinned ? "" : "warning: source is unpinned (ipsw = \"latest\")\n"
            output.result(
                RecipeSummary(recipe, path: path),
                text: "\(warning)\(path): \(recipe.cpus) CPUs, \(recipe.memory) memory, \(recipe.disk) disk, \(recipe.provisioners.count) provision step(s)"
            )
        }
    }
}

private extension IPSWCatalog.Image {
    var releasedDay: String { released.formatted(.iso8601.year().month().day()) }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build a new VM from a recipe.")

    @Argument(help: "Name of the new VM.")
    var name: String

    @Argument(help: ArgumentHelp("Recipe file.", valueName: "recipe"))
    var path: String = Recipe.fileName

    @Flag(help: "If the build fails, keep the VM running for SSH until ^C, then delete it.")
    var holdOnFailure = false

    @Flag(help: "Print progress and the new VM as JSON Lines events.")
    var json = false

    @MainActor
    func run() async throws {
        let output = Output(json: json, streaming: true)
        try await output.reporting {
            let recipeFile = URL(filePath: path)
            if !FileManager.default.fileExists(atPath: recipeFile.path) {
                let hint = path == Recipe.fileName ? " (run hobo init, or pass a recipe path)" : ""
                throw CLIError("no recipe at \(path)\(hint)")
            }
            let options = VMCreator.Options(name: name, recipeFile: recipeFile, holdOnFailure: holdOnFailure)
            let config = try await VMCreator(options: options, log: output.log).create()
            output.result(
                VMSummary(try VMStore.standard().find(name)),
                text: "Created \(name): macOS \(config.guestOSVersion), \(config.cpus) CPUs, \(ByteSize(bytes: config.memory)) memory"
            )
        }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List VMs.")

    @Flag(help: "Print each VM's state, size and configuration as JSON (sizes in bytes).")
    var json = false

    func run() {
        let store = VMStore.standard()
        let vms = store.list()
        if json {
            Output(json: true).result(vms.map(VMSummary.init), text: "")
            return
        }
        guard !vms.isEmpty else {
            print("No VMs in \(store.directory.path).")
            return
        }
        let rows = [["NAME", "STATE", "OS", "CPUS", "MEMORY", "DISK (USED/SIZE)"]] + vms.map { vm in
            let used = fileSize(vm.allocatedBytes)
            switch vm.status {
            case .stopped(let config):
                return [vm.name, "stopped"] + columns(config, used: used)
            case .running(let config, _):
                return [vm.name, "running"] + columns(config, used: used)
            case .crashed(let config, let status):
                return [vm.name, "crashed (\(status < 0 ? "signal \(-status)" : "exit \(status)"))"] + columns(config, used: used)
            case .building: return [vm.name, "building", "—", "—", "—", "\(used) / —"]
            case .failed: return [vm.name, "failed", "—", "—", "—", "\(used) / —"]
            case .broken: return [vm.name, "broken", "—", "—", "—", "\(used) / —"]
            }
        }
        print(formatTable(rows))
    }

    private func columns(_ config: VMConfig, used: String) -> [String] {
        ["\(config.os.rawValue) \(config.guestOSVersion)", String(config.cpus), fileSize(config.memory), "\(used) / \(fileSize(config.disk))"]
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a VM headless, in the background under launchd.",
        discussion: "Waits until the guest answers SSH. Interrupting the wait leaves the VM booting."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print progress and the VM's status (state, PID, IP address) as JSON Lines events.")
    var json = false

    func run() async throws {
        let output = Output(json: json, streaming: true)
        let name = name
        let interrupt = signalSource(SIGINT) {
            let message = "interrupted; left \(name) booting (hobo stop \(name) to stop it)"
            if output.isJSON { output.fail(message) } else { print("\n" + message.prefix(1).uppercased() + message.dropFirst()) }
            Darwin.exit(130)
        }
        defer { interrupt.cancel() }
        try await output.reporting {
            let result = try await VMLifecycle(log: output.log).start(name)
            let text = switch result {
            case .started(let status): "\(name) is running\(status.ipAddress.map { " (\($0))" } ?? "")"
            case .alreadyRunning(let status): "\(name) is already running\(status?.ipAddress.map { " (\($0))" } ?? "")"
            }
            output.result(result, text: text)
        }
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shut a VM down.",
        discussion: "Runs shutdown over SSH if the guest answers, otherwise asks the guest to shut down, then powers it off if it is still on."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Power the VM off at once, and kill its VM process if it isn't answering.")
    var force = false

    @Flag(help: "Print progress and the outcome as JSON Lines events.")
    var json = false

    func run() async throws {
        let output = Output(json: json, streaming: true)
        try await output.reporting {
            let result = try await VMLifecycle(log: output.log).stop(name, force: force)
            let text = switch result {
            case .stopped: "Stopped \(name)"
            case .wasNotRunning: "\(name) is not running"
            }
            output.result(result, text: text)
        }
    }
}

/// The VM process launchd runs for `hobo start`. Hidden, and dispatched by `Entry` before the
/// async commands, since it runs AppKit's event loop.
struct VMRun: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_vm-run", shouldDisplay: false)

    @Argument var name: String

    func run() throws {
        let name = name
        // `Entry` calls this on the main thread, before anything else is running.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // Never in the Dock and never takes focus; `hobo view` will add a window.
            app.setActivationPolicy(.accessory)
            Task {
                await VMRunner(name: name) { line in
                    print("\(Date.now.formatted(.iso8601)) \(line)")
                    fflush(stdout)
                }.start()
            }
            app.run()
        }
    }
}

/// Handles `signo` on a background queue instead of the default action, until cancelled.
private func signalSource(_ signo: Int32, _ handler: @escaping @Sendable () -> Void) -> any DispatchSourceSignal {
    signal(signo, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
    source.setEventHandler(handler: handler)
    source.setCancelHandler { signal(signo, SIG_DFL) }
    source.resume()
    return source
}

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a stopped VM.")

    @Argument(help: "Current name.")
    var old: String

    @Argument(help: "New name.")
    var new: String

    @Flag(help: "Print the renamed VM as JSON.")
    var json = false

    func run() throws {
        let output = Output(json: json)
        try output.reporting {
            let store = VMStore.standard()
            try store.rename(old, to: new)
            output.result(VMSummary(try store.find(new)), text: "Renamed \(old) to \(new)")
        }
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a VM and its bundle.")

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    @Flag(help: "Print the deleted VM's name as JSON. Needs --yes.")
    var json = false

    func validate() throws {
        if json && !yes { throw ValidationError("--json can't ask for confirmation; pass --yes too") }
    }

    func run() throws {
        let output = Output(json: json)
        try output.reporting {
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
            output.result(["deleted": vm.name], text: "Deleted \(vm.name)")
        }
    }
}

/// Left-aligned columns two spaces apart, the first row a header.
private func formatTable(_ rows: [[String]]) -> String {
    let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
    return rows.map { row in
        zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n")
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
