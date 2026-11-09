import AppKit
import Foundation
import HoboControl
import HoboCore
import HoboVM
import Observation

/// Hobo.app's state: the VMs as `hobo list` sees them, kept current by watching the store and the
/// VM processes' directory, and the actions the window offers. Every action is the core call the
/// matching CLI command makes, so the app and the CLI can't diverge.
@MainActor @Observable
public final class Library {
    public private(set) var vms: [VMSummary] = []
    public private(set) var loaded = false
    /// VMs with an action under way, by name, with what it is ("Starting").
    public private(set) var busy: [String: String] = [:]
    /// The build under way, if any: one at a time, since ^C-style cleanup on quit is per process.
    public private(set) var build: Build?
    /// The last action's failure, for an alert.
    public var failure: String?

    public let store: VMStore
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    public init(store: VMStore = .standard()) {
        self.store = store
    }

    /// A build in this process, with its log so far.
    @MainActor @Observable
    public final class Build {
        public let name: String
        public internal(set) var log: [String] = []
        /// Set when it fails; the sheet shows it until dismissed.
        public internal(set) var failure: String?
        public internal(set) var finished = false

        init(name: String) { self.name = name }
    }

    // MARK: Keeping current

    /// Starts watching: FSEvents on the store and on hobo's home (sockets, logs, plists), and a 5 s
    /// poll for what a VM process changes without touching disk, such as its window showing.
    public func startWatching() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher([store.directory, store.home.root]) { [weak self] in self?.refresh() }
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Lists the VMs again, off the main thread. Calls while one runs coalesce into one more.
    public func refresh() {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        let lifecycle = lifecycle
        Task {
            let listing = await Task.detached { await lifecycle.listing() }.value
            vms = listing.vms
            loaded = true
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
    }

    private var lifecycle: VMLifecycle { VMLifecycle(store: store) { _ in } }

    public func summary(named name: String) -> VMSummary? { vms.first { $0.name == name } }

    /// The VM's Dock icon (`VMIcon`), drawn once per name.
    public func icon(for name: String) -> NSImage? {
        if let icon = icons[name] { return icon }
        let icon = VMIcon.image(for: name)
        icons[name] = icon
        return icon
    }

    // MARK: Actions

    /// Runs `work` for `name` off the main thread, marked busy with `what`, then refreshes. A
    /// failure goes to `failure`.
    private func perform(_ what: String, on name: String, _ work: @escaping @Sendable () async throws -> Void) {
        busy[name] = what
        Task {
            do {
                try await Task.detached(operation: work).value
            } catch {
                failure = "\(error)"
            }
            busy[name] = nil
            refresh()
        }
    }

    public func start(_ name: String) {
        let lifecycle = lifecycle
        perform("Starting", on: name) { _ = try await lifecycle.start(name) }
    }

    public func stop(_ name: String, force: Bool = false) {
        let lifecycle = lifecycle
        perform("Stopping", on: name) { _ = try await lifecycle.stop(name, force: force) }
    }

    public func suspend(_ name: String) {
        let lifecycle = lifecycle
        perform("Suspending", on: name) { _ = try await lifecycle.suspend(name) }
    }

    public func discard(_ name: String) {
        let lifecycle = lifecycle
        perform("Discarding", on: name) { _ = try lifecycle.discard(name) }
    }

    public func showWindow(_ name: String) {
        let lifecycle = lifecycle
        perform("Opening", on: name) { try await lifecycle.view(name) }
    }

    public func clone(_ source: String, to destination: String) {
        let store = store
        perform("Cloning", on: source) { _ = try store.cloneVM(source, to: destination) { _ in } }
    }

    public func rename(_ old: String, to new: String) {
        let store = store
        perform("Renaming", on: old) { try store.rename(old, to: new) }
    }

    public func delete(_ name: String, force: Bool = false) {
        let lifecycle = lifecycle
        perform("Deleting", on: name) { try await lifecycle.delete(name, force: force) }
    }

    /// `hobo set` with the form's changes; does nothing if there are none.
    public func apply(_ form: SettingsForm, to name: String) {
        guard let config = summary(named: name)?.config else { return }
        let settings = form.settings(from: config)
        guard !settings.isEmpty else { return }
        let store = store
        perform("Saving", on: name) { _ = try settings.apply(to: name, store: store) { _ in } }
    }

    // MARK: Building

    /// Builds `name` from `recipe` in this process, as `hobo create` does (Create from Recipe…).
    public func create(_ name: String, recipe: URL) {
        startBuild(name) { _ in recipe }
    }

    /// Builds from the New VM sheet's form, writing its recipe to a temporary directory first. A
    /// Windows ISO is hashed first, as `hobo init --os windows` does, since the recipe pins it.
    public func create(from form: NewVMForm) {
        startBuild(form.name) { log in
            var sha256: String?
            if form.os == .windows, let iso = form.windowsISO {
                try WindowsInstallMedia.validate(iso)
                sha256 = try await Task.detached { try ImageIndex.standard().hash(of: iso, log: log) }.value
            }
            return try NewVMForm.writeRecipe(try form.draft(windowsSHA256: sha256))
        }
    }

    private func startBuild(_ name: String, recipe: @escaping @MainActor (@escaping @Sendable (String) -> Void) async throws -> URL) {
        guard build == nil || build?.finished == true else {
            failure = "\(build!.name) is being built; one build at a time."
            return
        }
        let build = Build(name: name)
        self.build = build
        let log: @Sendable (String) -> Void = { line in
            Task { @MainActor in build.log.append(line) }
        }
        Task {
            do {
                let file = try await recipe(log)
                let options = VMCreator.Options(name: name, recipeFile: file)
                _ = try await VMCreator(store: store, options: options, log: log).create()
                build.finished = true
                self.build = nil
            } catch {
                build.failure = "\(error)"
                build.finished = true
            }
            refresh()
        }
    }

    /// Clears a failed build's sheet.
    public func dismissBuild() {
        if build?.finished == true { build = nil }
    }

    /// Whether quitting needs to ask first: it cancels a build, deleting the VM.
    public var buildInProgress: Bool { build.map { !$0.finished } ?? false }

    /// Quits during a build the way ^C does: `VMCreator`'s SIGTERM handler deletes the bundle and exits.
    public func cancelBuildAndQuit() {
        kill(getpid(), SIGTERM)
    }
}
