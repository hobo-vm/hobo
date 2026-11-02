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
        // `create` may need a window (a recipe's recoveryOS step), so in a GUI session it runs under
        // AppKit's loop; `.accessory` keeps it out of the Dock until a window shows. Elsewhere (SSH,
        // no window server) it runs like any other command, and such recipes fail before installing.
        let appKit = arguments.first == Create._commandName && CGSessionCopyCurrentDictionary() != nil
        if appKit { MainActor.assumeIsolated { _ = NSApplication.shared.setActivationPolicy(.accessory) } }
        Task {
            await HoboCommand.main()
            exit(0)
        }
        if appKit { MainActor.assumeIsolated { NSApplication.shared.run() } }
        dispatchMain()
    }
}

struct HoboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hobo",
        abstract: "Named VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [
            Init.self, Validate.self, Images.self, Create.self, List.self, Start.self, Stop.self, View.self,
            SSH.self, Exec.self, Copy.self, IP.self, SetCommand.self, Provision.self, Rename.self, Delete.self, Claude.self, Usage.self,
        ]
    )
}

/// The guest OS a catalog command is about.
enum GuestOSOption: String, ExpressibleByArgument, CaseIterable {
    case macos, linux
}

struct Init: OutputCommand {
    static let configuration = CommandConfiguration(abstract: "Write a starter \(Recipe.fileName) in the current directory.")

    @Option(help: "The guest OS: macos (an IPSW) or linux (an Ubuntu cloud image, with a desktop unless --server).")
    var os: GuestOSOption = .macos

    @Argument(help: ArgumentHelp(
        """
        What to pin the source to: a macOS build from `hobo images` (e.g. 26B123), or with --os linux an Ubuntu \
        version from `hobo images --os linux` (e.g. 26.04). Without one, macOS uses "latest" and Linux the newest LTS.
        """,
        valueName: "build-or-version"
    ))
    var build: String?

    @Flag(help: "With --os linux, leave out the desktop: the guest boots to a text console.")
    var server = false

    @Flag(help: "Overwrite an existing \(Recipe.fileName).")
    var force = false

    @Flag(help: "Print the recipe's path and the image it is pinned to as JSON.")
    var json = false

    func validate() throws {
        if server && os != .linux { throw ValidationError("--server is for --os linux") }
    }

    private struct Result: Encodable {
        var path: String
        var image: CatalogImage?
    }

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let url = URL.currentDirectory().appending(path: Recipe.fileName)
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw ValidationError("\(Recipe.fileName) already exists (use --force to overwrite)")
        }
        let image: CatalogImage?
        switch os {
        case .macos:
            if let build {
                image = .macOS(try IPSWCatalog.image(build: build, in: try await IPSWCatalog.fetch(), hostMajor: IPSWCatalog.hostMajor))
            } else {
                image = nil
            }
        case .linux:
            let catalog = try await UbuntuCatalog.fetch()
            let pinned = try build.map { try UbuntuCatalog.image(version: $0, in: catalog) } ?? UbuntuCatalog.newestLTS(in: catalog)
            if !pinned.supported { throw UbuntuCatalogError.unsupportedVersion(pinned.version) }
            image = .linux(pinned)
        }
        let template = switch image {
        case .macOS(let image): Recipe.template(pinnedTo: image)
        case .linux(let image): Recipe.template(pinnedTo: image, desktop: !server)
        case nil: Recipe.template
        }
        try template.write(to: url, atomically: true, encoding: .utf8)
        let pinned = switch image {
        case .macOS(let image): " pinned to \(image.name) \(image.version) (\(image.build))"
        case .linux(let image): " pinned to \(image.name), release \(image.serial)\(server ? "" : ", with a desktop")"
        case nil: ""
        }
        return Reply(Result(path: url.path, image: image), text: "Wrote \(Recipe.fileName)\(pinned)")
    }
}

/// An image from either catalog, encoded as the catalog's own record.
enum CatalogImage: Encodable {
    case macOS(IPSWCatalog.Image)
    case linux(UbuntuCatalog.Image)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .macOS(let image): try image.encode(to: encoder)
        case .linux(let image): try image.encode(to: encoder)
        }
    }
}

struct Images: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the images this Mac can build VMs from: macOS IPSWs, or Ubuntu cloud images.",
        discussion: """
            By default only the newest build of each macOS version, or the newest release of each supported Ubuntu \
            version, is listed. Pass a build or version to `hobo init` to start a recipe pinned to it. macOS IPSWs \
            come from ipsw.me, Ubuntu images from cloud-images.ubuntu.com.
            """
    )

    @Option(help: "The guest OS: macos (IPSWs) or linux (Ubuntu cloud images).")
    var os: GuestOSOption = .macos

    @Argument(help: ArgumentHelp(
        "Show the details of this macOS build (e.g. 26B123), or Ubuntu version (e.g. 26.04), instead of the list.",
        valueName: "build-or-version"
    ))
    var build: String?

    @Flag(help: "List every macOS build, or every release of each Ubuntu version, not only the newest.")
    var all = false

    @Flag(help: "Print the full records (URL, SHA-256, size in bytes, …) as JSON.")
    var json = false

    func validate() throws {
        if build != nil && all { throw ValidationError("--all lists images; it can't be combined with a build or version") }
    }

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        switch os {
        case .macos:
            let catalog = try await IPSWCatalog.fetch()
            if let build {
                let image = try IPSWCatalog.image(build: build, in: catalog)
                return Reply(image, text: details(image))
            }
            var images = IPSWCatalog.runnable(catalog, hostMajor: IPSWCatalog.hostMajor)
            if !all { images = IPSWCatalog.latestPerMajor(images) }
            return Reply(images, text: table(images))
        case .linux:
            let catalog = try await UbuntuCatalog.fetch()
            if let build {
                let image = try UbuntuCatalog.image(version: build, in: catalog)
                return Reply(image, text: details(image))
            }
            var images = UbuntuCatalog.supported(catalog)
            if !all { images = UbuntuCatalog.latestPerSeries(images) }
            return Reply(images, text: table(images))
        }
    }

    private func table(_ images: [IPSWCatalog.Image]) -> String {
        let rows = [["NAME", "VERSION", "BUILD", "RELEASED", "SIZE"]] + images.map { image in
            [image.name, image.version, image.build, image.releasedDay, formattedSize(image.size)]
        }
        return formatTable(rows)
    }

    private func table(_ images: [UbuntuCatalog.Image]) -> String {
        let rows = [["NAME", "VERSION", "CODENAME", "RELEASE", "SUPPORT ENDS", "SIZE"]] + images.map { image in
            [image.name, image.version, image.codename, image.serial, image.supportEnds.map(day) ?? "—", formattedSize(image.size)]
        }
        return formatTable(rows)
    }

    private func details(_ image: IPSWCatalog.Image) -> String {
        var text = labelledFields([
            ("Name", image.name), ("Version", image.version), ("Build", image.build),
            ("Released", image.releasedDay),
            ("Size", "\(formattedSize(image.size)) (\(image.size) bytes)"), ("URL", image.url.absoluteString),
            ("SHA-256", image.sha256), ("Signed", image.signed ? "yes" : "no"),
        ])
        if image.major > IPSWCatalog.hostMajor {
            text += "\n\nThis Mac (macOS \(IPSWCatalog.hostMajor)) can't run it: the guest is newer than the host."
        }
        return text
    }

    private func details(_ image: UbuntuCatalog.Image) -> String {
        var text = labelledFields([
            ("Name", image.name), ("Version", image.version), ("Codename", image.codename), ("Release", image.serial),
            ("Support", image.supported ? "until \(image.supportEnds.map(day) ?? "unknown")" : "ended"),
            ("Size", "\(formattedSize(image.size)) (\(image.size) bytes)"), ("URL", image.url.absoluteString),
            ("SHA-256", image.sha256),
        ])
        if !image.supported { text += "\n\nCanonical no longer supports this version, so `hobo init` won't pin it." }
        return text
    }

    private func labelledFields(_ fields: [(String, String)]) -> String {
        fields.map { label, value in label.padding(toLength: 10, withPad: " ", startingAt: 0) + value }.joined(separator: "\n")
    }
}

struct Validate: OutputCommand {
    static let configuration = CommandConfiguration(abstract: "Check a recipe without building it.")

    @Argument(help: ArgumentHelp("Recipe file.", valueName: "recipe"))
    var path: String = Recipe.fileName

    @Flag(help: "Print the recipe's settings as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let recipe = try Recipe.load(from: URL(filePath: path))
        try recipe.checkFilesExist()
        let warning = recipe.source.isPinned ? "" : "warning: source is unpinned (ipsw = \"latest\")\n"
        var settings = [
            recipe.os == .macOS ? "macOS" : "Linux",
            "\(recipe.cpus) CPUs", "\(recipe.memory) memory", "\(recipe.disk) disk",
            "\(recipe.provisioners.count) provision step(s)",
        ]
        if recipe.guiTesting != nil { settings.append("GUI testing") }
        if !recipe.security.sip { settings.append("SIP off") }
        if !recipe.security.amfi { settings.append("AMFI off") }
        return Reply(
            RecipeSummary(recipe, path: path),
            text: "\(warning)\(path): \(settings.joined(separator: ", "))"
        )
    }
}

private extension IPSWCatalog.Image {
    var releasedDay: String { day(released) }
}

private func day(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }

private func formattedSize(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

struct Create: OutputCommand {
    static let configuration = CommandConfiguration(abstract: "Build a new VM from a recipe.")

    @Argument(help: "Name of the new VM.")
    var name: String

    @Argument(help: ArgumentHelp("Recipe file.", valueName: "recipe"))
    var path: String = Recipe.fileName

    @Flag(help: "If the build fails, keep the VM running for SSH until ^C, then delete it.")
    var holdOnFailure = false

    @Flag(help: "Print progress and the new VM as JSON Lines events.")
    var json = false

    static let jsonStyle = Output.JSONStyle.events

    func execute(_ output: Output) async throws -> Reply {
        let recipeFile = URL(filePath: path)
        // Checked here too, since VMCreator reads the file itself, after it has made the bundle.
        if !FileManager.default.fileExists(atPath: recipeFile.path) { throw RecipeError.notFound(path) }
        let options = VMCreator.Options(name: name, recipeFile: recipeFile, holdOnFailure: holdOnFailure)
        let config = try await Self.create(options, output: output)
        return Reply(
            VMSummary(try VMStore.standard().find(name)),
            text: "Created \(name): \(config.osDescription), \(config.cpus) CPUs, \(ByteSize(bytes: config.memory)) memory"
        )
    }

    /// `VMCreator` runs on the main actor.
    @MainActor
    private static func create(_ options: VMCreator.Options, output: Output) async throws -> VMConfig {
        try await VMCreator(options: options, log: output.log, interrupted: output.interrupted).create()
    }
}

struct List: OutputCommand {
    static let configuration = CommandConfiguration(abstract: "List VMs.")

    @Flag(help: "Print each VM's state, size and configuration as JSON (sizes in bytes).")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let vms = store.list()
        let lifecycle = VMLifecycle(store: store) { _ in }
        var summaries = vms.map(VMSummary.init)
        for index in summaries.indices where summaries[index].state == .running {
            summaries[index].windowShown = await lifecycle.runStatus(summaries[index].name)?.windowShown
        }
        return Reply(summaries, text: vms.isEmpty ? "No VMs in \(store.directory.path)." : table(vms, summaries: summaries))
    }

    private func table(_ vms: [VMStore.VM], summaries: [VMSummary]) -> String {
        let rows = [["NAME", "STATE", "OS", "CPUS", "MEMORY", "DISK (USED/SIZE)"]] + zip(vms, summaries).map { vm, summary in
            let used = fileSize(vm.allocatedBytes)
            switch vm.status {
            case .stopped(let config):
                return [vm.name, "stopped"] + columns(config, used: used)
            case .running(let config, _):
                return [vm.name, summary.windowShown == true ? "running (window)" : "running"] + columns(config, used: used)
            case .crashed(let config, let status):
                return [vm.name, "crashed (\(status < 0 ? "signal \(-status)" : "exit \(status)"))"] + columns(config, used: used)
            case .building: return [vm.name, "building", "—", "—", "—", "\(used) / —"]
            case .failed: return [vm.name, "failed", "—", "—", "—", "\(used) / —"]
            case .broken: return [vm.name, "broken", "—", "—", "—", "\(used) / —"]
            }
        }
        return formatTable(rows)
    }

    private func columns(_ config: VMConfig, used: String) -> [String] {
        [config.osDescription, String(config.cpus), fileSize(config.memory), "\(used) / \(fileSize(config.disk))"]
    }
}

struct Start: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a VM in the background under launchd, headless unless --gui.",
        discussion: "Waits until the guest answers SSH. Interrupting the wait leaves the VM booting."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Open the VM's window once the guest is ready (or now, if it is already running).")
    var gui = false

    @Option(
        name: .customLong("share"),
        help: ArgumentHelp(
            "Share a host folder for this run only, read-only with :ro. Repeatable; the VM must be stopped.",
            valueName: "folder[:ro]"
        ),
        transform: parseShare
    )
    var shares: [VMShare] = []

    @Flag(help: "Print progress and the VM's status (state, PID, IP address) as JSON Lines events.")
    var json = false

    static let jsonStyle = Output.JSONStyle.events

    func execute(_ output: Output) async throws -> Reply {
        let name = name
        let interrupt = signalSource(SIGINT) {
            output.interrupted("left \(name) booting (hobo stop \(name) to stop it)")
            Darwin.exit(130)
        }
        defer { interrupt.cancel() }
        let result = try await VMLifecycle(log: output.log).start(name, gui: gui, shares: shares)
        let text = switch result {
        case .started(let status): "\(name) is running\(status.ipAddress.map { " (\($0))" } ?? "")"
        case .alreadyRunning(let status): "\(name) is already running\(status?.ipAddress.map { " (\($0))" } ?? "")"
        }
        return Reply(result, text: text)
    }
}

struct Stop: OutputCommand {
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

    static let jsonStyle = Output.JSONStyle.events

    func execute(_ output: Output) async throws -> Reply {
        let result = try await VMLifecycle(log: output.log).stop(name, force: force)
        let text = switch result {
        case .stopped: "Stopped \(name)"
        case .wasNotRunning: "\(name) is not running"
        }
        return Reply(result, text: text)
    }
}

struct IP: OutputCommand {
    static let configuration = CommandConfiguration(commandName: "ip", abstract: "Print a running VM's IP address.")

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print the VM's name and IP address as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let address = try GuestChannel().address(name)
        return Reply(address, text: address.ipAddress)
    }
}

struct SSH: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "SSH into a running VM, or run a command there with -- <command>.",
        discussion: """
            Runs the system ssh as the vagrant user, so the session, exit status and any command behave as plain ssh's do. \
            There is no --json: hobo exec runs a command and reports its exit status as JSON.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print the ssh command instead of running it.")
    var print = false

    @Argument(parsing: .postTerminator, help: ArgumentHelp("A command to run instead of a login shell.", valueName: "command"))
    var command: [String] = []

    func run() throws {
        let store = VMStore.standard()
        let vm = try store.find(name)
        let ssh = GuestSSH(host: try GuestChannel(store: store).ipAddress(vm.name), auth: try .forVM(bundle: vm.bundle, home: store.home))
        if print {
            Swift.print(ssh.commandLine(command))
            return
        }
        let argv = ["ssh"] + ssh.sshArguments(command)
        let cArgs = argv.map { strdup($0) } + [nil]
        execv(GuestSSH.sshPath, cArgs)
        throw CLIError("can't run \(GuestSSH.sshPath): \(String(cString: strerror(errno)))")
    }
}

struct Exec: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in a running VM.",
        discussion: """
            The command runs as the vagrant user, without stdin or a TTY, and hobo exits with its status. \
            Its arguments are quoted for the guest's shell, so use sh -c '<script>' for pipes and the like.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print the command's exit status as JSON; its output goes to stderr.")
    var json = false

    @Argument(parsing: .postTerminator, help: ArgumentHelp("The command, after --.", valueName: "command"))
    var command: [String] = []

    static let jsonStyle = Output.JSONStyle.document

    func validate() throws {
        if command.isEmpty { throw ValidationError("give the command after --, e.g. hobo exec \(name) -- uname -a") }
    }

    func execute(_ output: Output) async throws -> Reply {
        let status = try GuestChannel().exec(name, command: command, onOutput: writeOutput)
        return Reply(GuestCommandResult(exitStatus: status), text: nil, exitStatus: status)
    }
}

struct Copy: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files between the host and a running VM.",
        discussion: "One side names the guest as <vm>:<path>, e.g. hobo cp ./app dev:/tmp/ or hobo cp dev:/var/log/system.log . (runs scp)."
    )

    @Flag(name: .shortAndLong, help: "Copy directories recursively.")
    var recursive = false

    @Flag(help: "Print scp's exit status as JSON; its messages go to stderr.")
    var json = false

    @Argument(help: ArgumentHelp("Sources, then the destination.", valueName: "path"))
    var paths: [String] = []

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let (vm, copy) = try GuestCopy.parse(paths, recursive: recursive, currentDirectory: .currentDirectory())
        let status = try GuestChannel().copy(vm, copy, onOutput: writeOutput)
        return Reply(GuestCommandResult(exitStatus: status), text: nil, exitStatus: status)
    }
}

/// Writes a guest command's output to the matching stream of this process. With `--json`,
/// `Output` has pointed fd 1 at stderr, so stdout carries only the JSON.
private func writeOutput(_ stream: GuestStream, _ data: Data) throws {
    switch stream {
    case .stdout: try FileHandle.standardOutput.write(contentsOf: data)
    case .stderr: try FileHandle.standardError.write(contentsOf: data)
    }
}

struct View: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a running VM's window.",
        discussion: "Closing the window asks whether to keep the VM running headless or shut it down."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print the VM's name as JSON once its window is showing.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        try await VMLifecycle(log: output.log).view(name)
        return Reply(["name": name], text: nil)
    }
}

/// The VM process launchd runs for `hobo start`. Hidden, and dispatched by `Entry` before the
/// async commands, since it runs AppKit's event loop.
struct VMRun: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_vm-run", shouldDisplay: false)

    @Argument var name: String
    @Flag var gui = false
    /// `start --share`, as `VMShare.argument` wrote them: absolute paths.
    @Option(name: .customLong("share")) var shares: [String] = []

    func run() throws {
        let name = name
        let gui = gui
        let runShares = try shares.map { try VMShare.parse($0, currentDirectory: URL(filePath: "/")) }
        // `Entry` calls this on the main thread, before anything else is running.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // Never in the Dock, and takes focus only when `hobo view` or `--gui` shows the window.
            app.setActivationPolicy(.accessory)
            Task {
                await VMRunner(name: name, gui: gui, runShares: runShares) { line in
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

struct SetCommand: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change a stopped VM's CPUs, memory, disk size or shared folders.",
        discussion: """
            The disk only grows. Its image grows now, and the guest's APFS container grows into the new space \
            at the next hobo start.

            A shared folder appears in the guest at /Volumes/My Shared Files/<folder name>. --unshare runs before \
            --share, so --unshare src --share ~/src:ro makes a share read-only.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Option(help: "Number of virtual CPUs.")
    var cpus: Int?

    @Option(help: ArgumentHelp("Memory, e.g. 16GB.", valueName: "size"), transform: { try ByteSize(parsing: $0) })
    var memory: ByteSize?

    @Option(help: ArgumentHelp("Disk size, e.g. 120GB. It can only grow.", valueName: "size"), transform: { try ByteSize(parsing: $0) })
    var disk: ByteSize?

    @Option(
        name: .customLong("share"),
        help: ArgumentHelp("Share a host folder, read-only with :ro. Repeatable.", valueName: "folder[:ro]"),
        transform: parseShare
    )
    var shares: [VMShare] = []

    @Option(
        name: .customLong("unshare"),
        help: ArgumentHelp("Stop sharing a folder, given by its share name or host path. Repeatable.", valueName: "name|folder")
    )
    var unshares: [String] = []

    @Flag(help: "Print the updated VM as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    private var settings: VMSettings {
        VMSettings(
            cpus: cpus, memory: memory, disk: disk, addShares: shares,
            removeShares: unshares.map { VMShare.unshareTarget($0, currentDirectory: .currentDirectory()) }
        )
    }

    func validate() throws {
        if settings.isEmpty { throw ValidationError("give at least one of --cpus, --memory, --disk, --share or --unshare") }
    }

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let config = try settings.apply(to: name, store: store, log: output.log)
        let vm = try store.find(name)
        var lines = ["\(vm.name): \(config.cpus) CPUs, \(fileSize(config.memory)) memory, \(fileSize(config.disk)) disk"]
        lines += config.shares.map { "Sharing \($0.path) as \($0.name)\($0.readOnly ? " (read-only)" : "")" }
        if config.diskGrowPending { lines.append("The guest grows into the larger disk at the next hobo start \(vm.name).") }
        return Reply(VMSummary(vm), text: lines.joined(separator: "\n"))
    }
}

struct Provision: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a recipe's [[provision]] steps again on a running VM.",
        discussion: """
            Runs every step in order without rebuilding, for trying out a recipe's steps or bringing a VM up to date \
            with its recipe. The rest of the recipe is ignored. Steps run again in full, so they should be safe to repeat.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Argument(help: ArgumentHelp("Recipe file.", valueName: "recipe"))
    var path: String = Recipe.fileName

    @Flag(help: "Print progress and the outcome as JSON Lines events.")
    var json = false

    static let jsonStyle = Output.JSONStyle.events

    func execute(_ output: Output) async throws -> Reply {
        let result = try await Provisioning.provision(name, recipeFile: URL(filePath: path), log: output.log)
        return Reply(result, text: "Provisioned \(result.name) (\(result.steps) step\(result.steps == 1 ? "" : "s"))")
    }
}

struct Rename: OutputCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a stopped VM.")

    @Argument(help: "Current name.")
    var old: String

    @Argument(help: "New name.")
    var new: String

    @Flag(help: "Print the renamed VM as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        try store.rename(old, to: new)
        return Reply(VMSummary(try store.find(new)), text: "Renamed \(old) to \(new)")
    }
}

struct Delete: OutputCommand {
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

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let vm = try store.find(name)
        try store.checkNotRunning(vm)
        // The prompt is text only: validate() requires --yes with --json.
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                throw CLIError("refusing to delete \(vm.name) without a terminal to confirm (pass --yes)")
            }
            print("Delete VM \"\(vm.name)\" (\(fileSize(vm.allocatedBytes)))? [y/N] ", terminator: "")
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                return Reply(["deleted": String?.none], text: "Not deleted.")
            }
        }
        try store.delete(vm.name)
        return Reply(["deleted": vm.name], text: "Deleted \(vm.name)")
    }
}

/// `hobo claude install|uninstall`: the Claude Code skill (`ClaudeSkill`).
struct Claude: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the hobo skill for Claude Code.",
        subcommands: [ClaudeInstall.self, ClaudeUninstall.self]
    )
}

/// Where `hobo claude install|uninstall` acts, and the skill they act on.
struct ClaudeSkillOptions: ParsableArguments {
    @Flag(help: "Use the current git repository's .claude/skills instead of ~/.claude/skills.")
    var project = false

    @Flag(help: "Replace or remove a hobo skill directory that hobo didn't write.")
    var force = false

    @Flag(help: "Print the skill's path as JSON.")
    var json = false

    func skill() throws -> ClaudeSkill {
        project ? try .project(containing: .currentDirectory()) : .global()
    }
}

struct ClaudeInstall: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Write the hobo skill to ~/.claude/skills/hobo (or the project's), replacing hobo's earlier copy."
    )

    @OptionGroup var options: ClaudeSkillOptions
    var json: Bool { options.json }
    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let skill = try options.skill()
        try skill.install(force: options.force)
        return Reply(["installed": skill.file.path], text: "Installed \(skill.file.path)")
    }
}

struct ClaudeUninstall: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the hobo skill from ~/.claude/skills/hobo (or the project's)."
    )

    @OptionGroup var options: ClaudeSkillOptions
    var json: Bool { options.json }
    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let skill = try options.skill()
        let removed = try skill.uninstall(force: options.force)
        let path = skill.directory.path
        return Reply(["removed": removed ? path : nil], text: removed ? "Removed \(path)" : "No hobo skill at \(path)")
    }
}

/// A `--share` argument, resolved against the current directory.
private func parseShare(_ argument: String) throws -> VMShare {
    try VMShare.parse(argument, currentDirectory: .currentDirectory())
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
