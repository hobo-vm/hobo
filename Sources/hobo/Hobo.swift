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
        abstract: "Ephemeral VMs on Apple's Virtualization framework.",
        version: Hobo.version,
        subcommands: [
            Init.self, Validate.self, Images.self, Create.self, List.self, Start.self, Stop.self, Suspend.self, Discard.self, View.self,
            SSH.self, Exec.self, Copy.self, Remove.self, Screenshot.self, UICommand.self, IP.self, SetCommand.self, Provision.self, Clone.self, SnapshotCommand.self, Rename.self, Delete.self, Claude.self, Usage.self,
        ]
    )
}

/// The guest OS a catalog command is about.
enum GuestOSOption: String, ExpressibleByArgument, CaseIterable {
    case macos, linux, windows
}

struct Init: OutputCommand {
    static let configuration = CommandConfiguration(abstract: "Write a starter recipe: \(Recipe.fileName), or the file -o names.")

    @Option(help: "The guest OS: macos (an IPSW), linux (an Ubuntu cloud image, with a desktop unless --server) or windows (an installer ISO you downloaded).")
    var os: GuestOSOption = .macos

    @Argument(help: ArgumentHelp(
        """
        What to pin the source to: a macOS build from `hobo images` (e.g. 26B123), or with --os linux an Ubuntu \
        version from `hobo images --os linux` (e.g. 26.04), or with --os windows the path of a Windows on Arm ISO. \
        Without one, macOS uses "latest" and Linux the newest LTS; Windows needs one.
        """,
        valueName: "build-version-or-iso"
    ))
    var pin: String?

    @Flag(help: "With --os linux, leave out the desktop: the guest boots to a text console.")
    var server = false

    @Option(name: [.customShort("o"), .customLong("output")], help: ArgumentHelp(
        "Recipe file to write, for keeping several recipes in one directory (e.g. linux.toml).",
        valueName: "recipe"
    ))
    var recipeFile: String = Recipe.fileName

    @Flag(help: "Overwrite an existing recipe file.")
    var force = false

    @Flag(help: "Print the recipe's path and the image it is pinned to as JSON.")
    var json = false

    private var recipeURL: URL { URL(filePath: recipeFile).absoluteURL }

    func validate() throws {
        if server && os != .linux { throw ValidationError("--server is for --os linux") }
        var isDirectory: ObjCBool = false
        let namesADirectory = recipeFile.isEmpty || recipeFile.hasSuffix("/")
            || (FileManager.default.fileExists(atPath: recipeURL.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        if namesADirectory {
            throw ValidationError("-o names the recipe file to write, not a directory (e.g. \((recipeFile as NSString).appendingPathComponent(Recipe.fileName)))")
        }
    }

    private struct Result: Encodable {
        var path: String
        var image: CatalogImage?
    }

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let url = recipeURL
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw ValidationError("\(recipeFile) already exists (use --force to overwrite)")
        }
        let image: CatalogImage?
        switch os {
        case .macos:
            if let pin {
                image = .macOS(try IPSWCatalog.image(build: pin, in: try await IPSWCatalog.fetch(), hostMajor: IPSWCatalog.hostMajor))
            } else {
                image = nil
            }
        case .linux:
            let catalog = try await UbuntuCatalog.fetch()
            let pinned = try pin.map { try UbuntuCatalog.image(version: $0, in: catalog) } ?? UbuntuCatalog.newestLTS(in: catalog)
            if !pinned.supported { throw UbuntuCatalogError.unsupportedVersion(pinned.version) }
            image = .linux(pinned)
        case .windows:
            guard let pin else { throw ValidationError(WindowsInstallMedia.bringYourOwnISO) }
            let iso = URL(filePath: pin)
            try WindowsInstallMedia.validate(iso)
            image = .windows(WindowsISO(path: iso.path, sha256: try ImageIndex.standard().hash(of: iso, log: output.log)))
        }
        let source: RecipeDraft.Source = switch image {
        case .macOS(let image): .macOS(image)
        case .linux(let image): .linux(image, desktop: !server)
        case .windows(let iso): .windows(iso: iso.path, sha256: iso.sha256)
        case nil: .macOS(nil)
        }
        try RecipeDraft(source: source).text().write(to: url, atomically: true, encoding: .utf8)
        let pinned = switch image {
        case .macOS(let image): " pinned to \(image.name) \(image.version) (\(image.build))"
        case .linux(let image): " pinned to \(image.name), release \(image.serial)\(server ? "" : ", with a desktop")"
        case .windows(let iso): " pinned to \(URL(filePath: iso.path).lastPathComponent)"
        case nil: ""
        }
        return Reply(Result(path: url.path, image: image), text: "Wrote \(recipeFile)\(pinned)")
    }
}

/// A Windows installer the user downloaded, since Microsoft has no catalog to pick one from.
struct WindowsISO: Encodable {
    var path: String
    var sha256: String
}

/// The image a recipe was pinned to: from a catalog, encoded as the catalog's own record, or an ISO.
enum CatalogImage: Encodable {
    case macOS(IPSWCatalog.Image)
    case linux(UbuntuCatalog.Image)
    case windows(WindowsISO)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .macOS(let image): try image.encode(to: encoder)
        case .linux(let image): try image.encode(to: encoder)
        case .windows(let iso): try iso.encode(to: encoder)
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

    @Option(help: "The guest OS: macos (IPSWs) or linux (Ubuntu cloud images). With windows, says where to get an ISO, since there is no catalog.")
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
            var images = IPSWCatalog.buildable(catalog, hostMajor: IPSWCatalog.hostMajor)
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
        case .windows:
            throw ValidationError(WindowsInstallMedia.bringYourOwnISO)
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
        } else if image.major < IPSWCatalog.minimumGuestMajor {
            text += "\n\nhobo can't build a VM from it: it builds from macOS \(IPSWCatalog.minimumGuestMajor) or later."
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
        let os = switch recipe.os {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows"
        }
        var settings = [
            os,
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
    static let configuration = CommandConfiguration(
        abstract: "List VMs and the disk space they use.",
        discussion: """
            ADDRESS is a running VM's IP address. USED is a VM's own files, in full even where a clone shares them. SNAPSHOTS is how many it \
            has and what they hold beyond its own files. TOTAL counts every block once, snapshots \
            included, so it can be less than the rows add up to when clones share blocks.
            """
    )

    @Flag(name: .shortAndLong, help: "Also list each VM's snapshots, each with what deleting it alone would free.")
    var verbose = false

    @Flag(help: #"Print {"vms":[…],"totalBytes":…,…} (sizes in bytes). Each VM has its name, state and snapshots at the top, and what it is set to (os, cpus, memory, ephemeral, guiTesting, …) under "config"."#)
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let listing = await VMLifecycle(store: store) { _ in }.listing()
        return Reply(listing, text: listing.vms.isEmpty ? "No VMs in \(store.directory.path)." : table(listing))
    }

    private func table(_ listing: VMListing) -> String {
        let vmRows = listing.vms.map { summary in
            Self.row(summary) + [Self.snapshotsCell(count: summary.snapshots?.count ?? 0, bytes: summary.snapshotBytes ?? 0)]
        }
        let total = ["TOTAL", "", "", "", "", "", fileSize(listing.totalBytes), Self.snapshotsCell(count: listing.snapshotCount, bytes: listing.totalSnapshotBytes)]
        let rows = [["NAME", "STATE", "ADDRESS", "OS", "CPUS", "MEMORY", "DISK (USED/SIZE)", "SNAPSHOTS"]] + vmRows + [total]
        return verbose ? Self.tableWithSnapshots(rows, snapshots: listing.vms.map { $0.snapshots ?? [] }) : formatTable(rows)
    }

    /// The table of `rows` (a header, a row per VM, the total), with each VM's snapshots after its
    /// line, lined up under the STATE column.
    static func tableWithSnapshots(_ rows: [[String]], snapshots: [[Snapshot]]) -> String {
        let indent = String(repeating: " ", count: (rows.map { $0[0].count }.max() ?? 0) + 2)
        let lines = formatTable(rows).components(separatedBy: "\n")
        let snapshotsUnderLines = [[]] + snapshots + [[]] // Neither the header nor the total has any.
        return zip(lines, snapshotsUnderLines).flatMap { line, snapshots -> [String] in
            guard !snapshots.isEmpty else { return [line] }
            let details = formatTable(snapshots.map { [$0.tag, $0.isLive ? "live" : "disk", createdText($0), fileSize($0.uniqueBytes ?? 0)] })
            return [line] + details.components(separatedBy: "\n").map { indent + $0 }
        }.joined(separator: "\n")
    }

    static func snapshotsCell(count: Int, bytes: UInt64) -> String {
        // Bytes with no snapshot to list are what a failed save left behind, which still count.
        count == 0 && bytes == 0 ? "—" : "\(count) (\(fileSize(bytes)))"
    }

    /// A VM's cells for every column but SNAPSHOTS.
    static func row(_ summary: VMSummary) -> [String] {
        let used = fileSize(summary.allocatedBytes)
        let state = stateCell(summary)
        // Building, failed and broken VMs have no config.
        let address = summary.ipAddress ?? ""
        guard let config = summary.config else { return [summary.name, state, address, "—", "—", "—", "\(used) / —"] }
        return [summary.name, state, address] + columns(config, used: used)
    }

    private static func stateCell(_ summary: VMSummary) -> String {
        let state = switch summary.state {
        case .running: runningState(summary)
        case .suspended: "suspended (\(fileSize(summary.savedStateBytes ?? 0)))"
        case .crashed: crashedState(exitStatus: summary.exitStatus ?? 0)
        case .stopped, .building, .failed, .broken: summary.state.rawValue
        }
        guard summary.config?.ephemeral == true else { return state }
        return [state, "ephemeral", idleTimeoutState(summary)].compactMap { $0 }.joined(separator: ", ")
    }

    /// An ephemeral VM's idle timeout, for a VM plainly running whose process answered (only then is
    /// `windowShown` set). A showing window explains itself, and holds the countdown.
    private static func idleTimeoutState(_ summary: VMSummary) -> String? {
        guard summary.state == .running, summary.phase == nil, summary.windowShown == false else { return nil }
        if let remaining = summary.idleSecondsRemaining { return timeLeft(seconds: remaining) + " left" }
        return summary.idleTimeoutSeconds == nil ? "no timeout" : "busy"
    }

    /// `45s`, `28m` or `1h 30m`: up to the next minute, with seconds only under a minute.
    private static func timeLeft(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        // Not `(seconds + 59) / 60`: `--idle-timeout` takes values large enough to overflow that.
        let minutes = seconds / 60 + (seconds % 60 == 0 ? 0 : 1)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h" + (minutes % 60 == 0 ? "" : " \(minutes % 60)m")
    }

    private static func crashedState(exitStatus status: Int32) -> String {
        "crashed (\(status < 0 ? "signal \(-status)" : "exit \(status)"))"
    }

    /// `running`, `running (window)`, or what the process is doing instead, e.g.
    /// `stopping (saving state)` during a suspend.
    private static func runningState(_ summary: VMSummary) -> String {
        if let phase = summary.phase { return phase + (summary.phaseDetail.map { " (\($0))" } ?? "") }
        return summary.windowShown == true ? "running (window)" : "running"
    }

    private static func columns(_ config: VMConfig, used: String) -> [String] {
        [config.osDescription, String(config.cpus), fileSize(config.memory), "\(used) / \(fileSize(config.disk))"]
    }
}

struct Start: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a VM in the background under launchd, headless unless --gui, or resume it if suspended.",
        discussion: "Waits until the guest answers. Interrupting the wait leaves the VM booting."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Open the VM's window once the guest is ready (or now, if it is already running).")
    var gui = false

    @Flag(help: "Boot a suspended VM fresh, discarding its saved state, instead of resuming it.")
    var cold = false

    @Option(
        name: .customLong("share"),
        help: ArgumentHelp(
            "Share a host folder for this run only, read-only with :ro. Repeatable; the VM must be stopped (or suspended, with --cold).",
            valueName: "folder[:ro]"
        ),
        transform: parseShare
    )
    var shares: [VMShare] = []

    @Flag(help: "Boot a new clone of the VM instead, deleted when it stops. The VM must be stopped.")
    var ephemeral = false

    @Option(
        help: ArgumentHelp(
            """
            How long an ephemeral VM may sit idle before it stops, which deletes it: 90s, 30m, 2h, or off. Defaults to \
            \(IdleTimeout.standard). Using the VM through hobo resets the clock; raw SSH doesn't.
            """,
            valueName: "duration"
        ),
        transform: IdleTimeout.init(parsing:)
    )
    var idleTimeout: IdleTimeout?

    @Flag(help: #"Print progress as {"event":"log","message":…} lines, then {"event":"result","result":{"name":…,"outcome":…,"status":{"state":…,"pid":…,"ipAddress":…}}}. With --ephemeral, result.name is the clone's."#)
    var json = false

    static let jsonStyle = Output.JSONStyle.events

    func validate() throws {
        if ephemeral && cold { throw ValidationError("--cold and --ephemeral can't go together: a suspended VM can't be cloned") }
    }

    func execute(_ output: Output) async throws -> Reply {
        // An ephemeral clone's name is only known once it exists, so a ^C names its source.
        let interruptedMessage = ephemeral
            ? "left the ephemeral clone of \(self.name) booting (hobo list shows it; hobo stop deletes it)"
            : "left \(self.name) booting (hobo stop \(self.name) to stop it)"
        let interrupt = signalSource(SIGINT) {
            output.interrupted(interruptedMessage)
            Darwin.exit(130)
        }
        defer { interrupt.cancel() }
        let lifecycle = VMLifecycle(log: output.log)
        let (name, result) = ephemeral
            ? try await lifecycle.startEphemeral(from: self.name, gui: gui, shares: shares, idleTimeout: idleTimeout)
            : (self.name, try await lifecycle.start(self.name, gui: gui, cold: cold, shares: shares, idleTimeout: idleTimeout))
        let text = switch result {
        case .started(let status): "\(name) is running\(Self.details(status))"
        case .resumed(let status): "\(name) resumed\(Self.details(status))"
        case .alreadyRunning(let status): "\(name) is already running\(Self.details(status))"
        }
        return Reply(NamedStartResult(name: name, result: result), text: text)
    }

    /// What follows the outcome: e.g. ` (192.168.64.5); deleted after 30m idle`. The timeout is said
    /// up front because a VM that expires leaves nothing behind to say why it is gone.
    static func details(_ status: VMRunStatus?) -> String {
        let address = status?.ipAddress.map { " (\($0))" } ?? ""
        let timeout = status?.idleTimeoutSeconds.map { "; deleted after \(IdleTimeout.after(seconds: $0)) idle" } ?? ""
        return address + timeout
    }
}

struct Stop: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shut a VM down.",
        discussion: "Runs shutdown in the guest if it answers, otherwise asks the guest to shut down, then powers it off if it is still on."
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
        case .deleted: "Stopped and deleted \(name), which was ephemeral"
        case .wasNotRunning: "\(name) is not running"
        }
        return Reply(result, text: text)
    }
}

struct Suspend: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a running VM's memory and device state and stop it.",
        discussion: "hobo start resumes it where it left off; hobo discard throws the saved state away."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print progress and the outcome as JSON Lines events.")
    var json = false

    static let jsonStyle = Output.JSONStyle.events

    func execute(_ output: Output) async throws -> Reply {
        let result = try await VMLifecycle(log: output.log).suspend(name)
        let text = switch result {
        case .suspended(let bytes): "Suspended \(name) (\(fileSize(bytes)) saved state)"
        case .alreadySuspended: "\(name) is already suspended"
        case .wasNotRunning: "\(name) is not running"
        }
        return Reply(result, text: text)
    }
}

struct Discard: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Throw a suspended VM's saved state away, leaving it stopped (or deleting it, if it is ephemeral).",
        discussion: "Whatever was in the guest's memory is lost, as if it had lost power."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print the outcome as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let result = try VMLifecycle(log: output.log).discard(name)
        let text = switch result {
        case .discarded: "Discarded \(name)'s saved state"
        case .deleted: "Discarded \(name)'s saved state and deleted it, which was ephemeral"
        case .notSuspended: "\(name) is not suspended"
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

struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "SSH into a running VM, or run a command there with -- <command>.",
        discussion: """
            Runs the system ssh as the hobo user, so the session, exit status and any command behave as plain ssh's do. \
            There is no --json: hobo exec runs a command and reports its exit status as JSON.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print the ssh command instead of running it.")
    var print = false

    @Argument(parsing: .postTerminator, help: ArgumentHelp("A command to run instead of a login shell.", valueName: "command"))
    var command: [String] = []

    func run() async throws {
        let store = VMStore.standard()
        let vm = try store.find(name)
        let ssh = GuestSSH(host: try GuestChannel(store: store).ipAddress(vm.name), auth: try .forVM(bundle: vm.bundle, home: store.home))
        if print {
            Swift.print(ssh.commandLine(command))
            return
        }
        // `start` returns once hobo-agent answers, which can be before sshd does.
        try await ssh.waitUntilReachable(timeout: .seconds(60))
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
            The command runs as the hobo user, without stdin or a TTY, and hobo exits with its status. \
            It returns when the command exits: a process the command left running in the background \
            (sh -c 'server >server.log 2>&1 &') keeps running, and what that writes to the command's output from then on is dropped. \
            Its arguments are quoted for the guest's shell, so use sh -c '<script>' (on Windows, powershell.exe -Command '<script>') \
            for pipes and the like. \
            With --gui it waits up to a minute for the desktop session, and exits 125 if it never comes up \
            (at once on a Linux guest with no desktop). \
            On macOS, privacy prompts for what it runs (Photos, Automation and the like) name hobo-agent as the app \
            asking, not the command, since macOS holds the agent responsible for it; the grants given go to hobo-agent too.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Run in the hobo user's desktop session rather than a background one.")
    var gui = false

    @Flag(help: "Print the command's exit status as JSON; its output goes to stderr.")
    var json = false

    @Argument(parsing: .postTerminator, help: ArgumentHelp("The command, after --.", valueName: "command"))
    var command: [String] = []

    static let jsonStyle = Output.JSONStyle.document

    func validate() throws {
        if command.isEmpty { throw ValidationError("give the command after --, e.g. hobo exec \(name) -- uname -a") }
    }

    func execute(_ output: Output) async throws -> Reply {
        let status = try GuestChannel().exec(name, command: command, gui: gui, onOutput: writeOutput)
        return Reply(GuestCommandResult(exitStatus: status), text: nil, exitStatus: status)
    }
}

struct Copy: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files between the host and a running VM.",
        discussion: "One side names the guest as <vm>:<path>, as in hobo cp dev:/var/log/system.log . (guest to host) or hobo cp ./app dev:/tmp/ (host to guest); a guest path that is relative, or starts ~/, is from the hobo user's home, as for hobo rm. A directory is copied with everything in it, and placed as scp would: inside a destination directory that exists, under its own name, otherwise as the destination itself; unlike scp, one directory onto a directory of its own name (./App.app onto dev:/Applications/App.app) is that directory, unless the destination ends in /. The directories above a destination are made if they aren't there. Copying onto a directory that is already there merges into it; --replace removes it first. A file never replaces a directory, or a directory a file: that copy fails."
    )

    /// Accepted because `cp -r` and `scp -r` are habit; a directory is copied whole without it.
    @Flag(name: .shortAndLong, help: "Has no effect: directories are always copied whole.")
    var recursive = false

    @Flag(help: "Remove whatever a source would land on first, so a directory that is already there is replaced, not merged into.")
    var replace = false

    @Flag(help: "Print the copy's exit status as JSON; its messages go to stderr.")
    var json = false

    @Argument(help: ArgumentHelp("Sources, then the destination.", valueName: "path"))
    var paths: [String] = []

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let (vm, copy) = try GuestCopy.parse(paths, replace: replace, currentDirectory: .currentDirectory())
        let status = try GuestChannel().copy(vm, copy, onOutput: writeOutput)
        return Reply(GuestCommandResult(exitStatus: status), text: status == 0 ? Self.text(paths: paths, replace: replace) : nil, exitStatus: status)
    }

    /// What a copy that worked prints, with the paths as they were given, so a script or an agent
    /// needn't look in the guest to know it did.
    static func text(paths: [String], replace: Bool) -> String {
        let sources = paths.dropLast()
        let what = sources.count == 1 ? sources[0] : "\(sources.count) items"
        return "Copied \(what) to \(paths.last ?? "")\(replace ? ", replacing what was there" : "")"
    }
}

struct Remove: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove files or directories inside a running VM (not the VM: that's hobo delete).",
        discussion: """
            Every path names the guest as <vm>:<path>, as in hobo rm dev:/tmp/MyApp.app, all in one VM; \
            a relative path, or one starting ~/, is from the hobo user's home. A directory is removed with everything in it, \
            as the hobo user. It refuses the filesystem root, the home directory and what holds it. \
            A path that isn't there fails the command unless --force, but the others are still removed.
            """
    )

    /// Accepted because `rm -r` is habit; a directory is removed whole without it.
    @Flag(name: .shortAndLong, help: "Has no effect: directories are always removed whole.")
    var recursive = false

    @Flag(name: .shortAndLong, help: "Don't fail for a path that isn't there.")
    var force = false

    @Flag(help: "Print the removal's exit status as JSON; its messages go to stderr.")
    var json = false

    @Argument(help: ArgumentHelp("Paths in the VM, as <vm>:<path>.", valueName: "vm:path"))
    var paths: [String] = []

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let (vm, remove) = try GuestRemove.parse(paths, force: force)
        let status = try GuestChannel().remove(vm, remove, onOutput: writeOutput)
        return Reply(GuestCommandResult(exitStatus: status), text: status == 0 ? Self.text(paths: paths, force: force) : nil, exitStatus: status)
    }

    /// What a removal that worked prints, with the paths as they were given, as `hobo cp` does.
    /// With `--force` a path may never have been there, which the host isn't told.
    static func text(paths: [String], force: Bool) -> String {
        let what = paths.count == 1 ? paths[0] : "\(paths.count) paths"
        let missing = paths.count == 1 ? "it wasn't" : "they weren't"
        return "Removed \(what)\(force ? " (or \(missing) there)" : "")"
    }
}

/// Writes a guest command's output to the matching stream of this process. With `--json`,
/// `Output` has pointed fd 1 at stderr, so stdout carries only the JSON.
func writeOutput(_ stream: GuestStream, _ data: Data) throws {
    switch stream {
    case .stdout: try FileHandle.standardOutput.write(contentsOf: data)
    case .stderr: try FileHandle.standardError.write(contentsOf: data)
    }
}

extension ScreenshotCrop: ExpressibleByArgument {
    public init?(argument: String) { self.init(argument) }
}

struct Screenshot: OutputCommand {
    /// The path that means this process's stdout.
    private static let standardOutput = "-"

    static let configuration = CommandConfiguration(
        abstract: "Save a PNG of a running VM's screen.",
        discussion: """
            Captures from inside the guest's desktop session, which on macOS needs a VM built from a recipe with [gui_testing], \
            and on Linux a desktop (left out by init --os linux --server). \
            Prints the file's path; by default it is a new <vm>-<timestamp>.png in the current directory. \
            --crop keeps one rectangle of the screen, such as an element's frame from hobo ui snapshot.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Argument(help: ArgumentHelp("Where to write the PNG, replacing what's there; - for stdout.", valueName: "path"))
    var path: String?

    @Option(name: [.customShort("o"), .customLong("output")], help: ArgumentHelp("The same as <path>.", valueName: "path"))
    var outputOption: String?

    // Unconditional, since a window partly off the screen's left has a frame that starts with "-".
    @Option(parsing: .unconditional, help: ArgumentHelp(
        "Keep only this rectangle, in screenshot pixels from the top left. Also takes a frame as hobo ui snapshot prints it: \"x,y width×height\".",
        valueName: "x,y,width,height"
    ))
    var crop: ScreenshotCrop?

    /// Where the PNG goes: the positional path or `--output`, whichever was given.
    private var output: String? { path ?? outputOption }

    @Flag(help: "Print the VM's name and the file's path as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func validate() throws {
        if path != nil && outputOption != nil { throw ValidationError("give the path once: as <path> or with --output") }
        if json && output == Self.standardOutput { throw ValidationError("--json can't go with a path of -: stdout has the PNG") }
    }

    func execute(_: Output) async throws -> Reply {
        var screenshot = try GuestChannel().screenshot(name)
        if let crop { screenshot = try screenshot.cropped(to: crop) }
        if output == Self.standardOutput {
            try FileHandle.standardOutput.write(contentsOf: screenshot.png)
            return Reply(ScreenshotResult(name: screenshot.name, path: Self.standardOutput), text: nil)
        }
        let file = try screenshot.save(to: output)
        return Reply(ScreenshotResult(name: screenshot.name, path: file.path), text: file.path)
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
    /// With --gui: show the window without activating hobo (a restore bringing it back).
    @Flag(name: .customLong("no-activate")) var noActivate = false
    /// `start --share`, as `VMShare.argument` wrote them: absolute paths.
    @Option(name: .customLong("share")) var shares: [String] = []
    /// `start --idle-timeout`, as `IdleTimeout.description` wrote it.
    @Option(name: .customLong("idle-timeout"), transform: IdleTimeout.init(parsing:)) var idleTimeout: IdleTimeout?

    func run() throws {
        let name = name
        let gui = gui
        let activateWindow = !noActivate
        let idleTimeout = idleTimeout
        let runShares = try shares.map { try VMShare.parse($0, currentDirectory: URL(filePath: "/")) }
        // `Entry` calls this on the main thread, before anything else is running.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // Never in the Dock, and takes focus only when `hobo view` or `--gui` shows the window.
            app.setActivationPolicy(.accessory)
            Task {
                await VMRunner(name: name, gui: gui, activateWindow: activateWindow, runShares: runShares, idleTimeout: idleTimeout) { line in
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
        abstract: "Change a stopped VM's CPUs, memory, disk size or shared folders, or keep an ephemeral VM.",
        discussion: """
            The disk only grows. Its image grows now, and the guest's filesystem grows into the new space \
            at the next hobo start.

            A shared folder appears in the guest at /Volumes/My Shared Files/<folder name> (macOS), \
            /mnt/hobo/<folder name> (Linux) or Z:\\<folder name> (Windows). --unshare runs before --share, so \
            --unshare src --share ~/src:ro makes a share read-only.

            --keep works on a running or suspended VM too.
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

    @Flag(help: "Keep an ephemeral VM: it stays when it stops instead of being deleted.")
    var keep = false

    @Flag(help: "Print the updated VM as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    private var settings: VMSettings {
        VMSettings(
            cpus: cpus, memory: memory, disk: disk, addShares: shares,
            removeShares: unshares.map { VMShare.unshareTarget($0, currentDirectory: .currentDirectory()) },
            keep: keep
        )
    }

    func validate() throws {
        if settings.isEmpty { throw ValidationError("give at least one of --cpus, --memory, --disk, --share, --unshare or --keep") }
    }

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let config = try settings.apply(to: name, store: store, log: output.log)
        let vm = try store.find(name)
        var lines = ["\(vm.name): \(config.cpus) CPUs, \(fileSize(config.memory)) memory, \(fileSize(config.disk)) disk"]
        lines += config.shares.map { "Sharing \($0.path) as \($0.name)\($0.readOnly ? " (read-only)" : "")" }
        if config.diskGrowPending { lines.append("The guest grows into the larger disk at the next hobo start \(vm.name).") }
        if keep { lines.append("\(vm.name) is kept: it stays when it stops.") }
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

struct Clone: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy a stopped VM to a new one, instantly on APFS.",
        discussion: """
            The clone has its own machine identifier and MAC address, so it can run beside the original. \
            It shares the original's disk blocks until either one changes them. Snapshots aren't copied.
            """
    )

    @Argument(help: "The VM to copy.")
    var source: String

    @Argument(help: "Name of the new VM.")
    var destination: String

    @Flag(help: "Delete the clone when it stops (hobo set --keep changes that). To clone and boot in one step, use hobo start <source> --ephemeral.")
    var ephemeral = false

    @Flag(help: "Print the new VM as JSON.")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let vm = try store.cloneVM(source, to: destination, ephemeral: ephemeral, log: output.log)
        return Reply(VMSummary(vm), text: Self.text(source: source, clone: vm.name, ephemeral: ephemeral))
    }

    /// What was made, and how to boot it, since a clone is left stopped. For an ephemeral one, also
    /// the one step that clones and boots.
    static func text(source: String, clone: String, ephemeral: Bool) -> String {
        guard ephemeral else { return "Cloned \(source) to \(clone); hobo start \(clone) boots it" }
        return """
            Cloned \(source) to \(clone) (ephemeral: deleted when it stops); hobo start \(clone) boots it
            (hobo start \(source) --ephemeral clones and boots in one step)
            """
    }
}

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Save a VM's state under a tag, and go back to it later.",
        discussion: """
            A running or suspended VM's snapshot includes its memory, so restoring returns to that running moment. \
            A stopped VM's has only its disk. Snapshots live in the VM's bundle and are deleted with it.
            """,
        subcommands: [SnapshotSave.self, SnapshotRestore.self, SnapshotList.self, SnapshotDelete.self]
    )
}

struct SnapshotSave: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Snapshot a VM. A running VM pauses briefly and carries on; others aren't touched.",
        discussion: "Ephemeral VMs can't have snapshots (hobo set --keep keeps one). A tag can't be reused until it's deleted."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Argument(help: "Name for the snapshot.")
    var tag: String

    @Flag(help: "Print progress and the snapshot as JSON Lines events.")
    var json = false

    static let jsonStyle = Output.JSONStyle.events

    func execute(_ output: Output) async throws -> Reply {
        let snapshot = try await VMLifecycle(log: output.log).saveSnapshot(name, tag: tag)
        let kind = snapshot.savedStateBytes.map { "with \(fileSize($0)) of saved state" } ?? "disk only"
        return Reply(snapshot, text: "Saved snapshot \(snapshot.tag) of \(name) (\(kind))")
    }
}

struct SnapshotRestore: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Return a VM to a snapshot, replacing its disk. A snapshot with memory resumes running.",
        discussion: """
            The disk returns to its size then. CPUs and memory stay as they are now; if they have changed, \
            the snapshot's memory can't be used, and the VM boots from its disk with a warning. The snapshot is kept.
            """
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Argument(help: "The snapshot's tag.")
    var tag: String

    @Flag(help: "Restore over a running VM, powering it off, or a suspended one, discarding its saved state.")
    var force = false

    @Flag(help: "Print progress and the outcome as JSON Lines events.")
    var json = false

    static let jsonStyle = Output.JSONStyle.events

    func execute(_ output: Output) async throws -> Reply {
        let result = try await VMLifecycle(log: output.log).restoreSnapshot(name, tag: tag, force: force)
        let text = switch result {
        case .stopped: "\(name) is stopped, as it was at \(tag)"
        case .started(.resumed(let status)), .started(.started(let status)):
            "\(name) is running\(status.ipAddress.map { " at \($0)" } ?? "")"
        case .started(.alreadyRunning): "\(name) is running"
        }
        return Reply(result, text: text)
    }
}

struct SnapshotList: OutputCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List a VM's snapshots, oldest first.",
        discussion: "UNIQUE is what only that snapshot holds, which deleting it alone would free. Blocks two snapshots share are freed only once both are gone."
    )

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(help: "Print each snapshot as JSON (sizes in bytes).")
    var json = false

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let vm = try store.find(name)
        let snapshots = store.snapshots(of: vm)
        let rows = [["TAG", "KIND", "CREATED", "SAVED STATE", "UNIQUE"]] + snapshots.map { snapshot in
            [
                snapshot.tag, snapshot.isLive ? "live" : "disk", createdText(snapshot),
                snapshot.savedStateBytes.map(fileSize) ?? "—", fileSize(snapshot.uniqueBytes ?? 0),
            ]
        }
        return Reply(snapshots, text: snapshots.isEmpty ? "\(vm.name) has no snapshots." : formatTable(rows))
    }
}

struct SnapshotDelete: OutputCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a snapshot. The VM isn't touched, whatever its state.")

    @Argument(help: "Name of the VM.")
    var name: String

    @Argument(help: "The snapshot's tag.")
    var tag: String

    @Flag(help: "Print the outcome as JSON.")
    var json = false

    private struct Result: Encodable {
        var deleted: String
    }

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        try Snapshot.delete(tag, in: try VMStore.standard().find(name).bundle)
        return Reply(Result(deleted: tag), text: "Deleted snapshot \(tag) of \(name)")
    }
}

struct Rename: OutputCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rename a stopped or suspended VM.",
        discussion: "To rename a running VM without losing what it is doing, hobo suspend it, rename it, and hobo start it under its new name."
    )

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
    static let configuration = CommandConfiguration(abstract: "Delete a VM and its bundle. (hobo rm removes files inside a VM.)")

    @Argument(help: "Name of the VM.")
    var name: String

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    @Flag(help: "Don't ask for confirmation, and power off a running VM first, as stop --force does.")
    var force = false

    @Flag(help: "Print the deleted VM's name as JSON. Needs --yes or --force.")
    var json = false

    func validate() throws {
        if json && !yes && !force { throw ValidationError("--json can't ask for confirmation; pass --yes too") }
    }

    static let jsonStyle = Output.JSONStyle.document

    func execute(_ output: Output) async throws -> Reply {
        let store = VMStore.standard()
        let vm = try store.find(name)
        // Checked here as well as by the delete below, to refuse before asking rather than after.
        try store.checkStopped(vm, allowSuspended: true, allowRunning: force)
        // The prompt is text only: validate() requires --yes or --force with --json.
        if !yes && !force {
            guard isatty(STDIN_FILENO) != 0 else {
                throw CLIError("refusing to delete \(vm.name) without a terminal to confirm (pass --yes)")
            }
            let snapshotBytes = store.diskUsage().snapshotBytes[vm.name] ?? 0
            print("Delete VM \"\(vm.name)\" (\(fileSize(vm.allocatedBytes + snapshotBytes)))? [y/N] ", terminator: "")
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                return Reply(["deleted": String?.none], text: "Not deleted.")
            }
        }
        try await VMLifecycle(store: store, log: output.log).delete(vm.name, force: force)
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

private func createdText(_ snapshot: Snapshot) -> String {
    snapshot.record.createdAt.formatted(date: .abbreviated, time: .shortened)
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
