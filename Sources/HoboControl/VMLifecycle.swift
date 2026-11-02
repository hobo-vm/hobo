import Foundation
import HoboCore

/// Starts and stops VMs on behalf of a client (the CLI, later MCP). `start` registers the VM's
/// launchd job, which runs `hobo _vm-run <name>`; both then talk to that process over its socket.
public struct VMLifecycle: Sendable {
    public var store: VMStore
    /// The binary launchd runs as the VM process. It defaults to this one, so a client and the VM
    /// process it starts are always the same build and speak the same protocol.
    public var executable: URL
    public var log: @Sendable (String) -> Void

    public init(store: VMStore = .standard(), executable: URL? = nil, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.executable = executable ?? Bundle.main.executableURL!.resolvingSymlinksInPath()
        self.log = log
    }

    public enum StartResult: Equatable, Sendable {
        case started(VMRunStatus)
        /// The status is nil if the VM process didn't answer.
        case alreadyRunning(VMRunStatus?)
    }

    /// Boots `name` under launchd and waits until the guest answers SSH. A timeout leaves it booting.
    /// With `gui`, the VM's window opens once the guest answers SSH, or at once if it is already
    /// running. `shares` are for this run only, on top of the VM's own; they can't be added to a VM
    /// that's already running.
    public func start(
        _ name: String, gui: Bool = false, shares: [VMShare] = [], timeout: Duration = .seconds(10 * 60)
    ) async throws -> StartResult {
        let vm = try store.find(name)
        let job = store.job(for: vm.name)
        let config: VMConfig
        switch vm.status {
        case .running:
            if !shares.isEmpty { throw LifecycleError.sharesNeedStop(vm.name) }
            if gui { try await view(vm.name) }
            return .alreadyRunning(try? await ControlClient.status(at: job.socket))
        case .stopped(let stored), .crashed(let stored, _):
            config = stored
        case .building:
            throw VMStoreError.busy(vm.name, reason: "being built")
        case .failed:
            throw LifecycleError.notStartable(vm.name, "its build failed (hobo delete \(vm.name))")
        case .broken:
            throw LifecycleError.notStartable(vm.name, "its bundle has no valid \(VMStore.configFile)")
        }
        // Checked here, not left to the VM process, whose failure would only reach its log.
        if !(config.shares + shares).isEmpty { try VMShare.checkSupported(on: config.os) }
        guard Entitlements.has(Entitlements.virtualization) else { throw LifecycleError.unsigned(executable.path) }
        try ControlSocket.checkPath(job.socket.path)
        // Run-only shares were just typed, so a bad one fails here; a persistent share whose folder
        // has gone only warns, and the VM process leaves it out.
        for share in shares { try share.checkFolder() }
        try VMShare.checkNames(VMShare.available(config.shares, log: log) + shares)

        // A job left loaded by the last run (exited, maybe crashed) blocks bootstrapping a new one.
        store.launchd.bootout(job.label)
        try FileManager.default.createDirectory(at: job.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: job.log)
        let plist = try Launchd.plist(
            label: job.label,
            arguments: Self.runArguments(executable: executable, name: vm.name, gui: gui, shares: shares),
            environment: ["HOBO_VMS": store.directory.path, "HOBO_HOME": store.home.root.path],
            log: job.log
        )
        try plist.write(to: job.plist, options: .atomic)
        try store.launchd.bootstrap(job.plist)
        log("Starting \(vm.name)")
        return .started(try await waitUntilRunning(vm.name, job: job, timeout: timeout))
    }

    /// The VM process's command line, as launchd runs it.
    static func runArguments(executable: URL, name: String, gui: Bool, shares: [VMShare] = []) -> [String] {
        [executable.path, "_vm-run", name] + (gui ? ["--gui"] : []) + shares.flatMap { ["--share", $0.argument] }
    }

    /// Shows the window of a running (or booting) VM and brings it to the front.
    public func view(_ name: String) async throws {
        let vm = try store.find(name)
        guard vm.job?.pid != nil else { throw LifecycleError.notRunning(vm.name) }
        let response: ControlResponse
        do {
            response = try await ControlClient.send(.view, to: store.job(for: vm.name).socket)
        } catch {
            throw LifecycleError.unresponsive(vm.name, String(describing: error))
        }
        switch response {
        case .accepted: return
        case .error(let message): throw LifecycleError.refused(vm.name, message)
        default: throw ControlError.badMessage("expected an acknowledgement, got \(response)")
        }
    }

    public enum StopResult: Equatable, Sendable {
        case stopped
        case wasNotRunning
    }

    /// Asks the VM process to shut the guest down and waits for it to exit. With `force`, the VM
    /// is powered off at once, and a VM process that doesn't answer is killed.
    public func stop(_ name: String, force: Bool, timeout: Duration = .seconds(5 * 60)) async throws -> StopResult {
        let vm = try store.find(name)
        let job = store.job(for: vm.name)
        guard vm.job?.pid != nil else {
            // Clears a crashed run's exit status, so the VM shows as stopped.
            store.launchd.bootout(job.label)
            return .wasNotRunning
        }
        do {
            let response = try await ControlClient.send(.stop(force: force), to: job.socket)
            switch response {
            case .accepted: break
            case .error(let message): throw LifecycleError.refused(vm.name, message)
            default: throw ControlError.badMessage("expected an acknowledgement, got \(response)")
            }
        } catch {
            guard force else {
                throw error as? LifecycleError ?? LifecycleError.unresponsive(vm.name, String(describing: error))
            }
            // A refusal (e.g. a VM process from an older hobo) gets the same fallback as silence.
            log("The VM process isn't answering (\(error)); killing it")
            try store.launchd.kill(job.label, signal: "SIGKILL")
        }

        var lastDetail: String?
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard store.launchd.jobs()[job.label]?.pid != nil else {
                store.launchd.bootout(job.label)
                return .stopped
            }
            if case .status(let status)? = try? await ControlClient.send(.status, to: job.socket),
               let detail = status.detail, detail != lastDetail {
                log("  \(detail)")
                lastDetail = detail
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw LifecycleError.stopTimedOut(vm.name)
    }

    /// What a running VM's process reports, or nil if it doesn't answer within `timeout`. Short by
    /// default, so one wedged VM process can't stall a listing.
    public func runStatus(_ name: String, timeout: Duration = .seconds(1)) async -> VMRunStatus? {
        guard case .status(let status)? = try? await ControlClient.send(.status, to: store.job(for: name).socket, timeout: timeout)
        else { return nil }
        return status
    }

    /// How long a just-bootstrapped job may go without a process before `start` calls it exited:
    /// launchd can list the job before its process exists.
    static let launchGrace: Duration = .seconds(10)

    private func waitUntilRunning(_ name: String, job: VMJob, timeout: Duration) async throws -> VMRunStatus {
        var lastDetail: String?
        var sawProcess = false
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            let entry = store.launchd.jobs()[job.label]
            if entry?.pid != nil {
                sawProcess = true
            } else if sawProcess || ContinuousClock.now - started > Self.launchGrace {
                throw LifecycleError.exited(name, entry?.lastExitStatus, Self.tail(of: job.log))
            }
            if case .status(let status)? = try? await ControlClient.send(.status, to: job.socket) {
                switch status.state {
                case .running: return status
                case .stopping: throw LifecycleError.stoppedWhileStarting(name)
                case .starting: break
                }
                if let detail = status.detail, detail != lastDetail {
                    log("  \(detail)")
                    lastDetail = detail
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw LifecycleError.startTimedOut(name)
    }

    /// The last lines of a VM process's log, to show why it exited.
    static func tail(of log: URL, lines: Int = 20) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines + 1)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum LifecycleError: Error, Equatable, CustomStringConvertible {
    case notStartable(String, String)
    case unsigned(String)
    case exited(String, Int32?, String)
    case startTimedOut(String)
    case stoppedWhileStarting(String)
    case refused(String, String)
    case unresponsive(String, String)
    case stopTimedOut(String)
    case notRunning(String)
    case sharesNeedStop(String)

    public var description: String {
        switch self {
        case .notStartable(let name, let reason): "can't start \(name): \(reason)"
        case .unsigned(let path):
            "\(path) lacks the virtualization entitlement, so it can't run VMs (build it with make sign or make install)"
        case .exited(let name, let status, let log):
            "the VM process for \(name) exited\(status.map { " with status \($0)" } ?? "")"
                + (log.isEmpty ? "" : ":\n\(log)")
        case .startTimedOut(let name): "\(name) is still booting; it was left running (hobo list, or hobo stop \(name))"
        case .stoppedWhileStarting(let name): "\(name) was stopped while it was starting"
        case .refused(let name, let message): "the VM process for \(name) refused: \(message)"
        case .unresponsive(let name, let reason): "the VM process for \(name) isn't answering (\(reason)); hobo stop --force \(name) kills it"
        case .stopTimedOut(let name): "\(name) is still stopping (hobo stop --force \(name) powers it off)"
        case .notRunning(let name): "\(name) is not running (hobo start --gui \(name))"
        case .sharesNeedStop(let name):
            "\(name) is already running, and shares can't be added to a running VM (hobo stop \(name) first, or hobo set \(name) --share while it's stopped)"
        }
    }
}

/// `{"outcome": "started" | "alreadyRunning", "status": {...}}`; the status is absent if an
/// already-running VM process didn't answer.
extension VMLifecycle.StartResult: Encodable {
    private enum CodingKeys: String, CodingKey { case outcome, status }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .started(let status):
            try container.encode("started", forKey: .outcome)
            try container.encode(status, forKey: .status)
        case .alreadyRunning(let status):
            try container.encode("alreadyRunning", forKey: .outcome)
            try container.encodeIfPresent(status, forKey: .status)
        }
    }
}

/// `{"outcome": "stopped" | "wasNotRunning"}`.
extension VMLifecycle.StopResult: Encodable {
    private enum CodingKeys: String, CodingKey { case outcome }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stopped: try container.encode("stopped", forKey: .outcome)
        case .wasNotRunning: try container.encode("wasNotRunning", forKey: .outcome)
        }
    }
}
