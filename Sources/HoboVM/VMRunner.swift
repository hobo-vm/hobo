import Foundation
import HoboControl
import HoboCore
import Virtualization

/// The VM process, `hobo _vm-run <name>`: owns one running VM under launchd and serves its control
/// socket. It exits when the VM is off, with status 0 for a shutdown (by the guest or a `stop`)
/// and nonzero for a failure, which `hobo list` shows as crashed.
@MainActor
public final class VMRunner {
    static let gracefulTimeout: Duration = .seconds(30)
    static let sshShutdownTimeout: Duration = .seconds(2 * 60)
    static let bootTimeout: Duration = .seconds(10 * 60)
    nonisolated static let outputChunkBytes = 64 << 10

    let store: VMStore
    let name: String
    /// Whether to show the window as soon as the VM boots (`start --gui`).
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
        let config = try VMConfig.load(from: vm.bundle.appending(path: VMStore.configFile))
        guard config.engine == .vz, config.os == .macOS else { throw RunnerError.unsupported(config.engine, config.os) }
        guard let mac = VZMACAddress(string: config.macAddress) else { throw RunnerError.badMACAddress(config.macAddress) }

        server = try ControlServer(path: job.socket) { [weak self] request, reply in
            await self?.handle(request, reply: reply) ?? .error("the VM process is shutting down")
        }
        // Left by a suspend that died partway; `suspended/` appears only once a save is complete.
        try? FileManager.default.removeItem(at: SavedState.partialDirectory(in: vm.bundle))
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
                bundle: MacVMBundle(directory: vm.bundle), cpus: config.cpus, memoryBytes: config.memory, macAddress: mac, shares: shares
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
        if gui { showWindow(guest) }
        Task { await waitUntilReachable(guest, resumed: saved != nil) }
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
            if resumed {
                await setClock(guestSSH)
                if !shares.isEmpty { await remountShares(guestSSH) }
            }
            await growContainerIfPending(guestSSH)
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

    /// A resumed guest's clock is behind by however long it was suspended. NTP first, then the
    /// host's clock if the guest can't reach a time server; either failing only warns.
    private func setClock(_ ssh: GuestSSH) async {
        status.detail = "setting the guest's clock"
        if (try? await ssh.run("sudo -n sntp -sS time.apple.com", quiet: true)) == 0 { return }
        do {
            try await ssh.check(Self.setDateCommand(.now), what: "setting the guest's clock")
        } catch {
            log("warning: \(error); the guest's clock may be behind")
        }
    }

    /// A restored VM's virtio-fs device starts afresh on the host, so the guest's handles into
    /// the shares are stale: lookups fail with ENOENT (checked 2026-11-02 on 27.2) until the
    /// mount is replaced. Files the guest had open in a share are lost either way.
    private func remountShares(_ ssh: GuestSSH) async {
        status.detail = "remounting the shared folders"
        do {
            try await ssh.check(Self.remountSharesCommand, what: "remounting the shared folders")
        } catch {
            log("warning: \(error); the guest may not see its shared folders until it restarts")
        }
    }

    static let remountSharesCommand = {
        let mountPoint = shellQuote(MacVMBundle.sharesMountPoint)
        return "sudo -n umount -f \(mountPoint); sudo -n mkdir -p \(mountPoint) && "
            + "sudo -n mount -t virtiofs \(VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag) \(mountPoint)"
    }()

    /// Sets the guest's clock to `date`, passed in date(1)'s `mmddHHMMccyy.ss` form.
    nonisolated static func setDateCommand(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMddHHmmyyyy.ss"
        return "sudo -n date -u \(formatter.string(from: date)) >/dev/null"
    }

    /// Decision 9's second step: `hobo set --disk` grew the image while the VM was stopped, and
    /// the guest's APFS container grows into the new space live. A failure leaves the flag set,
    /// so the next boot tries again; the VM runs either way.
    private func growContainerIfPending(_ ssh: GuestSSH) async {
        let file = store.bundle(for: name).appending(path: VMStore.configFile)
        guard var config = try? VMConfig.load(from: file), config.diskGrowPending else { return }
        status.detail = "growing the guest's APFS container"
        log("Growing the guest's APFS container into the larger disk")
        do {
            try await ssh.check(Self.growContainerCommand, what: "growing the APFS container")
            config.diskGrowPending = false
            try config.write(to: file)
        } catch {
            log("warning: \(error); the next start tries again")
        }
    }

    /// Grows the boot volume's container (looked up, not assumed to be `disk0s2`) to fill its disk.
    static let growContainerCommand =
        #"sudo -n diskutil apfs resizeContainer "$(diskutil info / | awk '/APFS Physical Store:/ { print $NF }')" 0"#

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
            guard status.state != .stopping else { return .error("\(name) is shutting down") }
            guard let guest else { return .error("\(name) hasn't booted yet; try again in a moment") }
            // Its own task, so a client that hangs up can't cancel the save halfway.
            return await Task { await suspend(guest, reply: reply) }.value
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
            let window = VMWindow(guest: guest, title: name, log: log)
            window.onShutDown = { [weak self] in self?.beginStop(force: false) }
            self.window = window
        }
        window?.show()
    }

    /// Decision 11: pauses the VM, saves its state into `suspending/` and renames that into
    /// place, then powers the paused VM off and exits; the guest never runs past the save, so the
    /// disk stays as the state expects. A failed save is cleaned up and the VM resumed.
    private func suspend(_ guest: GuestVM, reply: ControlReply) async -> ControlResponse {
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
        try? reply.send(.accepted)
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
