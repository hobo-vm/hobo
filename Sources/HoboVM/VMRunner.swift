import Foundation
import HoboControl
import HoboCore
import Virtualization

/// The VM process, `hobo _vm-run <name>`: owns one running VM under launchd and serves its control
/// socket. It exits when the VM is off, with status 0 for a shutdown (by the guest or a `stop`)
/// and nonzero for a failure, which `hobo list` shows as crashed. An ephemeral VM is deleted as
/// its process exits either way, unless it was suspended.
@MainActor
public final class VMRunner {
    static let gracefulTimeout: Duration = .seconds(30)
    static let sshShutdownTimeout: Duration = .seconds(2 * 60)
    static let bootTimeout: Duration = .seconds(10 * 60)
    nonisolated static let outputChunkBytes = 64 << 10

    let store: VMStore
    let name: String
    /// Whether to show the window once the guest is ready (`start --gui`).
    let gui: Bool
    /// `start --share`: shares for this run only, on top of `config.json`'s.
    let runShares: [VMShare]
    let log: @Sendable (String) -> Void

    /// The process's one runner, held here because nothing else keeps it alive between control
    /// requests: once released, its socket would close while the VM ran on.
    private static var current: VMRunner?

    private var guest: GuestVM?
    /// The shares this run has, which a suspend records so the resumed run has the same.
    private var shares: [VMShare] = []
    private var window: VMWindow?
    private var server: ControlServer?
    private var status = VMRunStatus(state: .starting, pid: getpid(), detail: "booting")
    /// The snapshot being saved. The guest is paused for most of it, so nothing else may start.
    private var snapshotSave: Task<ControlResponse, Never>?
    /// The VM's name as its bundle spells it, once found; `name` may differ in case.
    private var bundleName: String?

    public init(
        store: VMStore = .standard(), name: String, gui: Bool = false, runShares: [VMShare] = [],
        log: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.name = name
        self.gui = gui
        self.runShares = runShares
        self.log = log
    }

    /// Boots the VM and returns; the process then lives until the VM stops, and exits from here.
    public func start() async {
        Self.current = self
        do {
            try await boot()
        } catch {
            log("error: \(error)")
            finish(1)
        }
    }

    private func boot() async throws {
        let vm = try store.find(name)
        let job = store.job(for: vm.name)
        // Every VM runs under launchd (always PID 1), whose job table is how clients see it.
        guard getppid() == 1 else { throw RunnerError.notUnderLaunchd(vm.name) }
        // Only from here may exiting delete an ephemeral VM: a stray `hobo _vm-run` mustn't.
        bundleName = vm.name
        let config = try VMConfig.load(from: vm.bundle.appending(path: VMStore.configFile))
        // From now on, the VM going without a process and saved state deletes it.
        if config.ephemeral { try Data().write(to: vm.bundle.appending(path: VMStore.startedMarker)) }
        guard config.engine == .vz, config.os != .windows else { throw RunnerError.unsupported(config.engine, config.os) }
        guard let mac = VZMACAddress(string: config.macAddress) else { throw RunnerError.badMACAddress(config.macAddress) }

        server = try ControlServer(path: job.socket) { [weak self] request, reply in
            await self?.handle(request, reply: reply) ?? .error("the VM process is shutting down")
        }
        // Left by a suspend that died partway; `suspended/` appears only once a save is complete.
        try? FileManager.default.removeItem(at: SavedState.partialDirectory(in: vm.bundle))
        Snapshot.removePartials(in: vm.bundle)
        let saved = SavedState.load(in: vm.bundle)
        if let saved {
            // The saved state fits only the run it came from, shares and all.
            guard let run = saved.run else { throw LifecycleError.cantResume(vm.name, "its \(SavedState.runFile) is unreadable") }
            shares = run.shares
        } else {
            shares = VMShare.available(config.shares + runShares, log: log)
        }
        // `hobo start` checked these, but config.json may have changed since; a bad or duplicate
        // name would otherwise trap building the share's directory map.
        try VMShare.checkNames(shares)
        let guest: GuestVM
        do {
            guest = try GuestVM(
                bundle: try vmBundle(at: vm.bundle, os: config.os), cpus: config.cpus, memoryBytes: config.memory,
                macAddress: mac, shares: shares
            )
        } catch where saved != nil {
            throw LifecycleError.cantResume(vm.name, String(describing: error))
        }
        guest.onStop = { [weak self] error in
            if let error { self?.log("error: the VM stopped: \(error)") } else { self?.log("The guest shut down") }
            self?.finish(error == nil ? 0 : 1)
        }
        self.guest = guest
        if saved != nil {
            try await resume(guest, from: SavedState.directory(in: vm.bundle))
        } else {
            log("Booting \(vm.name)")
            try await guest.start()
        }
        Task {
            await waitUntilReachable(guest, resumed: saved != nil)
            // Only once the guest answers SSH: its login prompt or login window shows well before
            // it is usable. After a timeout it shows anyway, so a stuck boot can be looked at.
            if gui, status.state != .stopping { showWindow(guest) }
        }
    }

    /// Restores the saved state and runs the guest on from it. The state is deleted before the
    /// guest runs: the disk moves on from then, so restoring it again would corrupt the disk.
    /// A failure leaves the guest unrun, and the state there for another try.
    private func resume(_ guest: GuestVM, from directory: URL) async throws {
        status.detail = "resuming"
        log("Resuming \(name) from its saved state")
        do {
            try await guest.restoreState(from: directory.appending(path: SavedState.stateFile))
        } catch {
            throw LifecycleError.cantResume(name, String(describing: error))
        }
        try FileManager.default.removeItem(at: directory)
        try await guest.resume()
    }

    private func waitUntilReachable(_ guest: GuestVM, resumed: Bool) async {
        do {
            status.detail = "waiting for a DHCP lease"
            let ip = try await guest.waitForIPAddress(timeout: Self.bootTimeout)
            status.ipAddress = ip
            status.detail = "waiting for SSH on \(ip)"
            let guestSSH = try ssh(ip)
            try await guestSSH.waitUntilReachable(timeout: Self.bootTimeout)
            let platform = type(of: guest.bundle)
            if resumed {
                await setClock(guestSSH, platform: platform)
                if !shares.isEmpty, let command = platform.remountSharesCommand {
                    await remountShares(guestSSH, command: command)
                }
            }
            await growDiskIfPending(guestSSH, platform: platform)
            guard status.state == .starting else { return }
            status.state = .running
            status.detail = nil
            log("Running at \(ip)")
        } catch {
            // The VM stays up, so it can still be stopped; `start` reports the timeout.
            log("warning: \(error)")
            if status.state == .starting { status.detail = "unreachable: \(error)" }
        }
    }

    /// A resumed guest's clock is behind by however long it was suspended. NTP first where the
    /// guest has it, then the host's clock; either failing only warns. NTP succeeding isn't taken
    /// on trust: a macOS guest has been seen ahead afterwards by the time it was frozen, so a clock
    /// still off the host's gets the host's time too.
    private func setClock(_ ssh: GuestSSH, platform: any VMBundle.Type) async {
        status.detail = "setting the guest's clock"
        if let ntp = platform.ntpClockCommand, (try? await ssh.run(ntp, quiet: true)) == 0,
           (try? await ssh.run(clockAgreesCommand(.now), quiet: true)) == 0 {
            return
        }
        do {
            try await ssh.check(platform.setClockCommand(.now), what: "setting the guest's clock")
        } catch {
            log("warning: \(error); the guest's clock may be behind")
        }
    }

    private func remountShares(_ ssh: GuestSSH, command: String) async {
        status.detail = "remounting the shared folders"
        do {
            try await ssh.check(command, what: "remounting the shared folders")
        } catch {
            log("warning: \(error); the guest may not see its shared folders until it restarts")
        }
    }

    /// Decision 9's second step: `hobo set --disk` grew the image while the VM was stopped, and
    /// the guest's root filesystem grows into the new space live. A failure leaves the flag set,
    /// so the next boot tries again; the VM runs either way.
    private func growDiskIfPending(_ ssh: GuestSSH, platform: any VMBundle.Type) async {
        let file = store.bundle(for: name).appending(path: VMStore.configFile)
        guard var config = try? VMConfig.load(from: file), config.diskGrowPending else { return }
        status.detail = "growing the guest's filesystem"
        log("Growing the guest's filesystem into the larger disk")
        do {
            try await ssh.check(platform.growDiskCommand, what: "growing the guest's filesystem")
            config.diskGrowPending = false
            try config.write(to: file)
        } catch {
            log("warning: \(error); the next start tries again")
        }
    }

    private func handle(_ request: ControlRequest, reply: ControlReply) async -> ControlResponse {
        switch request {
        case .status:
            var status = status
            status.windowShown = window?.isShown ?? false
            return .status(status)
        case .stop(let force):
            beginStop(force: force)
            return .accepted
        case .suspend:
            return await beginSuspend(reply: reply)
        case .snapshot(let tag):
            return await beginSnapshot(tag)
        case .view:
            guard status.state != .stopping else { return .error("\(name) is shutting down") }
            guard let guest else { return .error("\(name) hasn't booted yet; try again in a moment") }
            showWindow(guest)
            return .accepted
        case .exec(let command):
            return await withGuest(reply: reply) { ssh, onOutput in
                try await ssh.exec(command, onOutput: onOutput)
            }
        case .copy(let copy):
            return await withGuest(reply: reply) { ssh, onOutput in
                try await ssh.copy(copy, onOutput: onOutput)
            }
        }
    }

    /// Runs a streaming request against the guest once it answers SSH, sending its output to the
    /// client and ending with its exit status. A client that hangs up cancels it.
    private func withGuest(
        reply: ControlReply,
        _ body: (GuestSSH, @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32
    ) async -> ControlResponse {
        guard snapshotSave == nil else { return .error("\(name) is saving a snapshot; try again once that's done") }
        guard status.state == .running, let ip = status.ipAddress else {
            return .error("\(name) is \(status.state.rawValue)\(status.detail.map { " (\($0))" } ?? "")")
        }
        do {
            let code = try await body(try ssh(ip)) { stream, data in
                // Split so no message nears the control protocol's size limit once base64-encoded.
                for start in stride(from: data.startIndex, to: data.endIndex, by: Self.outputChunkBytes) {
                    let chunk = data[start..<min(start + Self.outputChunkBytes, data.endIndex)]
                    // A client that is gone also cancels the request; nothing more to do here.
                    try? reply.send(.output(stream, Data(chunk)))
                }
            }
            return .exited(code)
        } catch {
            return .error(String(describing: error))
        }
    }

    private func showWindow(_ guest: GuestVM) {
        if window == nil {
            let window = VMWindow(guest: guest, vmName: name, title: name, log: log)
            window.onShutDown = { [weak self] in self?.beginStop(force: false) }
            window.onSuspend = { [weak self] in
                guard let self else { return nil }
                if case .error(let message) = await beginSuspend(reply: nil) { return message }
                return nil
            }
            self.window = window
        }
        window?.show()
    }

    /// `suspend` from a client or the window's close dialog (which has no client to answer).
    private func beginSuspend(reply: ControlReply?) async -> ControlResponse {
        guard status.state != .stopping else { return .error("\(name) is shutting down") }
        // Not while starting: a failed save would hand the VM back as starting after the boot
        // sequence had stopped watching it, and a resumed guest may be mid clock or share fix-up.
        guard status.state == .running, let guest else {
            return .error("\(name) is still starting; try again once it is running")
        }
        guard snapshotSave == nil else { return .error("\(name) is saving a snapshot; try again once that's done") }
        // Its own task, so a client that hangs up can't cancel the save halfway.
        return await Task { await suspend(guest, reply: reply) }.value
    }

    /// `snapshot save` on a running VM. Not while it is starting, for the reason `suspend` gives.
    private func beginSnapshot(_ tag: String) async -> ControlResponse {
        guard status.state != .stopping else { return .error("\(name) is shutting down") }
        guard status.state == .running, let guest else {
            return .error("\(name) is still starting; try again once it is running")
        }
        guard snapshotSave == nil else { return .error("\(name) is already saving a snapshot; try again once that's done") }
        // Its own task, so a client that hangs up can't leave the guest paused.
        let save = Task { await saveSnapshot(tag, guest) }
        snapshotSave = save
        let response = await save.value
        snapshotSave = nil
        return response
    }

    /// Decision 13: pauses the VM, saves its state and clones its disk at that same instant, then
    /// resumes it. The partial folder comes first, so a tag already taken doesn't pause the guest.
    /// A failed save is cleaned up and the VM resumed either way.
    private func saveSnapshot(_ tag: String, _ guest: GuestVM) async -> ControlResponse {
        status.detail = "saving snapshot \(tag)"
        log("Saving snapshot \(tag)")
        defer { if status.state == .running { status.detail = nil } }
        let bundle = store.bundle(for: name)
        let partial: URL
        let config: VMConfig
        do {
            config = try VMConfig.load(from: bundle.appending(path: VMStore.configFile))
            partial = try Snapshot.begin(tag, in: bundle)
        } catch {
            return .error(String(describing: error))
        }
        do {
            try await guest.pause()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            log("error: snapshot \(tag) failed: \(error)")
            return .error("saving snapshot \(tag) of \(name) failed: \(error)")
        }
        var failure: (any Error)?
        do {
            let state = SavedState.directory(in: partial)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
            try await guest.saveState(to: state.appending(path: SavedState.stateFile))
            try SuspendedRun(shares: shares, suspendedAt: .now).write(to: state.appending(path: SavedState.runFile))
            try guest.bundle.copyPlatformFiles(to: partial)
            try Snapshot.finish(tag, partial: partial, in: bundle, config: config)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            log("error: snapshot \(tag) failed: \(error)")
            failure = error
        }
        do {
            try await guest.resume()
        } catch {
            log("error: resuming after snapshot \(tag) failed: \(error)")
            return .error("\(name) stayed paused after snapshot \(tag): \(error) (hobo stop --force \(name) powers it off)")
        }
        if let failure { return .error("saving snapshot \(tag) of \(name) failed: \(failure)") }
        // The guest's clock stood still during the pause.
        if status.state == .running, let ip = status.ipAddress, let ssh = try? ssh(ip) {
            await setClock(ssh, platform: type(of: guest.bundle))
        }
        log("Saved snapshot \(tag)")
        return .accepted
    }

    /// Decision 11: pauses the VM, saves its state into `suspending/` and renames that into
    /// place, then powers the paused VM off and exits; the guest never runs past the save, so the
    /// disk stays as the state expects. A failed save is cleaned up and the VM resumed.
    private func suspend(_ guest: GuestVM, reply: ControlReply?) async -> ControlResponse {
        let previous = (state: status.state, detail: status.detail)
        status.state = .stopping
        status.detail = "saving state"
        log("Suspend requested")
        let bundle = store.bundle(for: name)
        let partial = SavedState.partialDirectory(in: bundle)
        do {
            try await guest.pause()
            do {
                try? FileManager.default.removeItem(at: partial)
                try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
                try await guest.saveState(to: partial.appending(path: SavedState.stateFile))
                try SuspendedRun(shares: shares, suspendedAt: .now).write(to: partial.appending(path: SavedState.runFile))
                try FileManager.default.moveItem(at: partial, to: SavedState.directory(in: bundle))
            } catch {
                try? FileManager.default.removeItem(at: partial)
                do {
                    try await guest.resume()
                } catch let resumeError {
                    log("error: resuming after the failed save failed: \(resumeError)")
                }
                throw error
            }
        } catch {
            log("error: suspending failed: \(error)")
            status.state = previous.state
            status.detail = previous.detail
            return .error("suspending \(name) failed: \(error)")
        }
        log("Saved the VM's state; powering it off")
        // Answered now: once the process exits, the return value below can't be.
        try? reply?.send(.accepted)
        do {
            try await guest.forceStop()
        } catch {
            // Exiting ends the VM anyway; the saved state is what matters.
            log("warning: powering the paused VM off failed: \(error)")
        }
        finish(0)
    }

    /// A repeated stop is ignored unless it escalates to a forced one.
    private func beginStop(force: Bool) {
        guard status.state != .stopping || force else { return }
        status.state = .stopping
        Task { await stop(force: force) }
    }

    /// Decision 11: `shutdown -h now` over SSH if the guest answers, otherwise ask it (a virtual
    /// power-button press, which a macOS guest may only answer with a dialog), then power off.
    private func stop(force: Bool) async {
        guard let guest else { finish(0) }
        if !force {
            log("Stop requested")
            // A paused guest can't shut down. A forced stop doesn't wait: a save that hangs mustn't
            // keep the VM up, and the next boot clears what it leaves.
            _ = await snapshotSave?.value
            if let ip = status.ipAddress ?? DHCPLeases.ipAddress(forMAC: guest.macAddress.string),
               let ssh = try? ssh(ip), (try? await ssh.run("true", quiet: true)) == 0 {
                status.detail = "shutting down over SSH"
                // ssh usually drops mid-command here; the VM state is what matters.
                _ = try? await ssh.run("sudo -n shutdown -h now", quiet: true)
                if await stopped(guest, within: Self.sshShutdownTimeout) { finish(0) }
            } else {
                status.detail = "asking the guest to shut down"
                log("The guest doesn't answer SSH; asking it to shut down")
                if guest.requestStop(), await stopped(guest, within: Self.gracefulTimeout) { finish(0) }
            }
        }
        status.detail = "forcing the VM off"
        log(force ? "Forced stop requested" : "The guest didn't shut down; forcing it off")
        do {
            try await guest.forceStop()
            finish(0)
        } catch {
            log("error: forcing the VM off failed: \(error)")
            finish(1)
        }
    }

    /// Whether the guest is off within `timeout`; a VM that stopped with an error counts as off.
    private func stopped(_ guest: GuestVM, within timeout: Duration) async -> Bool {
        (try? await guest.waitForPowerOff(timeout: timeout)) ?? true
    }

    private func ssh(_ ip: String) throws -> GuestSSH {
        GuestSSH(host: ip, auth: try .forVM(bundle: store.bundle(for: name), home: store.home))
    }

    private func finish(_ code: Int32) -> Never {
        server?.close()
        // config.json is read again here, since `hobo set --keep` may have changed it meanwhile.
        if let bundleName, store.removeIfEphemeral(bundleName, keepLog: code != 0) { log("Deleted the ephemeral VM \(bundleName)") }
        log("Exiting (\(code))")
        exit(code)
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case notUnderLaunchd(String)
    case unsupported(VMConfig.Engine, VMConfig.OS)
    case badMACAddress(String)

    var description: String {
        switch self {
        case .notUnderLaunchd(let name): "the VM process for \(name) must be started by launchd (use hobo start \(name))"
        case .unsupported(let engine, let os): "\(os.rawValue) VMs on the \(engine.rawValue) engine can't run yet"
        case .badMACAddress(let mac): "config.json has an invalid MAC address \(mac)"
        }
    }
}
