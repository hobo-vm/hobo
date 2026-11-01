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

    let store: VMStore
    let name: String
    let log: @Sendable (String) -> Void

    /// The process's one runner, held here because nothing else keeps it alive between control
    /// requests: once released, its socket would close while the VM ran on.
    private static var current: VMRunner?

    private var guest: GuestVM?
    private var server: ControlServer?
    private var status = VMRunStatus(state: .starting, pid: getpid(), detail: "booting")

    public init(store: VMStore = .standard(), name: String, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.name = name
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

        server = try ControlServer(path: job.socket) { [weak self] request in
            await self?.handle(request) ?? .error("the VM process is shutting down")
        }
        let guest = try GuestVM(bundle: MacVMBundle(directory: vm.bundle), cpus: config.cpus, memoryBytes: config.memory, macAddress: mac)
        guest.onStop = { [weak self] error in
            if let error { self?.log("error: the VM stopped: \(error)") } else { self?.log("The guest shut down") }
            self?.finish(error == nil ? 0 : 1)
        }
        self.guest = guest
        log("Booting \(vm.name)")
        try await guest.start()
        Task { await waitUntilReachable(guest) }
    }

    private func waitUntilReachable(_ guest: GuestVM) async {
        do {
            status.detail = "waiting for a DHCP lease"
            let ip = try await guest.waitForIPAddress(timeout: Self.bootTimeout)
            status.ipAddress = ip
            status.detail = "waiting for SSH on \(ip)"
            try await ssh(ip).waitUntilReachable(timeout: Self.bootTimeout)
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

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request {
        case .status:
            return .status(status)
        case .stop(let force):
            if status.state != .stopping || force {
                status.state = .stopping
                Task { await stop(force: force) }
            }
            return .accepted
        }
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
        GuestSSH(host: ip, auth: .key(try store.home.ensureInsecurePrivateKey()))
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
