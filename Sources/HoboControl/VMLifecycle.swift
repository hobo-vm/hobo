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
        /// It was suspended, and carried on from its saved state.
        case resumed(VMRunStatus)
        /// The status is nil if the VM process didn't answer.
        case alreadyRunning(VMRunStatus?)
    }

    /// Boots `name` under launchd, or resumes it if it is suspended, and waits until the guest
    /// answers SSH. A timeout leaves it booting. `cold` discards a suspended VM's saved state and
    /// boots it instead. With `gui`, the VM's window opens once the guest answers SSH, or at once if
    /// it is already running. `shares` are for this run only, on top of the VM's own; they can't be
    /// added to a VM that's already running, or to a resumed one, whose saved state fits only the
    /// shares it had.
    public func start(
        _ name: String, gui: Bool = false, cold: Bool = false, shares: [VMShare] = [], timeout: Duration = .seconds(10 * 60)
    ) async throws -> StartResult {
        let vm = try store.find(name)
        let job = store.job(for: vm.name)
        let config: VMConfig
        var resuming = false
        switch vm.status {
        case .running:
            if !shares.isEmpty { throw LifecycleError.sharesNeedStop(vm.name) }
            if gui { try await view(vm.name) }
            return .alreadyRunning(try? await ControlClient.status(at: job.socket))
        case .suspended(let stored, let saved):
            config = stored
            if !cold {
                if !shares.isEmpty { throw LifecycleError.sharesNeedCold(vm.name) }
                guard let run = saved.run else { throw LifecycleError.cantResume(vm.name, "its \(SavedState.runFile) is unreadable") }
                // The VM process would fail on these too, but only its log would say why.
                do {
                    for share in run.shares { try share.checkFolder() }
                } catch {
                    throw LifecycleError.cantResume(vm.name, String(describing: error))
                }
                resuming = true
            }
        case .stopped(let stored), .crashed(let stored, _):
            config = stored
        case .building:
            throw VMStoreError.busy(vm.name, reason: "being built")
        case .failed:
            throw LifecycleError.notStartable(vm.name, "its build failed (hobo delete \(vm.name))")
        case .broken:
            throw LifecycleError.notStartable(vm.name, "its bundle has no valid \(VMStore.configFile)")
        }
        guard Entitlements.has(Entitlements.virtualization) else { throw LifecycleError.unsigned(executable.path) }
        try ControlSocket.checkPath(job.socket.path)
        if !resuming {
            // Run-only shares were just typed, so a bad one fails here; a persistent share whose
            // folder has gone only warns, and the VM process leaves it out.
            for share in shares { try share.checkFolder() }
            try VMShare.checkNames(VMShare.available(config.shares, log: log) + shares)
        }
        if cold, try store.discard(vm.name) { log("Discarded \(vm.name)'s saved state") }

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
        log(resuming ? "Resuming \(vm.name)" : "Starting \(vm.name)")
        let status = try await waitUntilRunning(vm.name, job: job, timeout: timeout)
        return resuming ? .resumed(status) : .started(status)
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
        /// It was ephemeral, so its VM process deleted it as it exited.
        case deleted
        case wasNotRunning
    }

    /// Asks the VM process to shut the guest down and waits for it to exit. With `force`, the VM
    /// is powered off at once, and a VM process that doesn't answer is killed.
    public func stop(_ name: String, force: Bool, timeout: Duration = .seconds(5 * 60)) async throws -> StopResult {
        let vm = try store.find(name)
        let job = store.job(for: vm.name)
        // Throwing the guest's memory away takes `hobo discard`, never a stop.
        if case .suspended = vm.status { throw LifecycleError.suspended(vm.name) }
        guard vm.job?.pid != nil else {
            // Clears a crashed run's exit status, so the VM shows as stopped.
            store.launchd.bootout(job.label)
            return .wasNotRunning
        }
        var killed = false
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
            killed = true
        }
        try await waitForExit(vm.name, job: job, timeout: timeout)
        // A killed process couldn't delete its ephemeral VM, so it is deleted here, keeping the log
        // as after any failed run. Left to `find`, the log would go too: after the bootout, a killed
        // run looks stopped rather than crashed.
        if killed { store.removeIfEphemeral(vm.name, keepLog: true) }
        // An ephemeral VM is gone by now, deleted by its process as it exited or by the line above.
        return (try? store.find(vm.name)) == nil ? .deleted : .stopped
    }

    /// `hobo delete`: deletes `name` and its bundle. With `force`, a running VM is powered off first
    /// (as by `stop` with `force`) rather than refused. A VM being built is always refused.
    public func delete(_ name: String, force: Bool) async throws {
        let vm = try store.find(name)
        try store.checkStopped(vm, allowSuspended: true, allowRunning: force)
        // Stopping an ephemeral VM deletes it, but a killed or failed run keeps its log, which
        // nothing would clean up once the VM is gone.
        if vm.job?.pid != nil, try await stop(vm.name, force: true) == .deleted {
            store.forgetJob(of: vm.name)
            return
        }
        try store.delete(vm.name)
    }

    public enum SuspendResult: Equatable, Sendable {
        case suspended(savedStateBytes: UInt64)
        case alreadySuspended(savedStateBytes: UInt64)
        case wasNotRunning
    }

    /// Has the VM process save the VM's state and exit, and waits for it. If the save fails, the
    /// VM keeps running and the VM process's error is thrown.
    public func suspend(_ name: String, timeout: Duration = .seconds(5 * 60)) async throws -> SuspendResult {
        let vm = try store.find(name)
        let job = store.job(for: vm.name)
        if case .suspended(_, let saved) = vm.status { return .alreadySuspended(savedStateBytes: saved.bytes) }
        guard vm.job?.pid != nil else { return .wasNotRunning }
        let response: ControlResponse
        do {
            // The answer comes once the state is saved, which takes a while for a large memory.
            response = try await ControlClient.send(.suspend, to: job.socket, timeout: timeout)
        } catch {
            throw LifecycleError.unresponsive(vm.name, String(describing: error))
        }
        switch response {
        case .accepted: break
        case .error(let message): throw LifecycleError.refused(vm.name, message)
        default: throw ControlError.badMessage("expected an acknowledgement, got \(response)")
        }
        let exitStatus = try await waitForExit(vm.name, job: job, timeout: timeout)
        guard let saved = SavedState.load(in: vm.bundle) else {
            throw LifecycleError.exited(vm.name, exitStatus, Self.tail(of: job.log))
        }
        return .suspended(savedStateBytes: saved.bytes)
    }

    public enum DiscardResult: Equatable, Sendable {
        case discarded
        /// It was ephemeral and had run, so with its saved state gone it was deleted.
        case deleted
        case notSuspended
    }

    /// `hobo discard`: throws a suspended VM's saved state away, leaving it stopped, or deleting it
    /// if it is ephemeral.
    public func discard(_ name: String) throws -> DiscardResult {
        let vm = try store.find(name)
        guard try store.discard(vm.name) else { return .notSuspended }
        // A resume that failed leaves its job's exit status, which would show the VM as crashed.
        store.launchd.bootout(store.job(for: vm.name).label)
        // Finding it again deletes it if it is ephemeral (`removeIfEphemeral`).
        return (try? store.find(vm.name)) == nil ? .deleted : .discarded
    }

    /// Waits for a VM process told to exit to do so, logging what it reports doing, then unloads
    /// its job. Returns its exit status.
    @discardableResult
    private func waitForExit(_ name: String, job: VMJob, timeout: Duration) async throws -> Int32? {
        var lastDetail: String?
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let entry = store.launchd.jobs()[job.label]
            guard entry?.pid != nil else {
                store.launchd.bootout(job.label)
                return entry?.lastExitStatus
            }
            if case .status(let status)? = try? await ControlClient.send(.status, to: job.socket),
               let detail = status.detail, detail != lastDetail {
                log("  \(detail)")
                lastDetail = detail
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw LifecycleError.stopTimedOut(name)
    }

    /// What `hobo list` reports: every VM with its disk usage and, for a running VM whose process
    /// answers, what that process says it is doing.
    public func listing() async -> VMListing {
        var listing = store.listing()
        for index in listing.vms.indices where listing.vms[index].state == .running {
            guard let status = await runStatus(listing.vms[index].name) else { continue }
            listing.vms[index].windowShown = status.windowShown
            if status.state != .running {
                listing.vms[index].phase = status.state.rawValue
                listing.vms[index].phaseDetail = status.detail
            }
        }
        return listing
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
    case sharesNeedCold(String)
    case suspended(String)
    case cantResume(String, String)

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
        case .sharesNeedCold(let name):
            "\(name) is suspended, and its saved state only fits the shares it had (hobo start --cold boots it fresh with new ones, discarding the saved state)"
        case .suspended(let name):
            "\(name) is suspended (hobo start \(name) resumes it; hobo discard \(name) throws its saved state away)"
        case .cantResume(let name, let reason):
            "can't resume \(name): \(reason) (hobo start --cold \(name) boots it fresh, discarding its saved state)"
        }
    }
}

/// `{"outcome": "started" | "resumed" | "alreadyRunning", "status": {...}}`; the status is absent
/// if an already-running VM process didn't answer.
extension VMLifecycle.StartResult: Encodable {
    private enum CodingKeys: String, CodingKey { case outcome, status }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .started(let status):
            try container.encode("started", forKey: .outcome)
            try container.encode(status, forKey: .status)
        case .resumed(let status):
            try container.encode("resumed", forKey: .outcome)
            try container.encode(status, forKey: .status)
        case .alreadyRunning(let status):
            try container.encode("alreadyRunning", forKey: .outcome)
            try container.encodeIfPresent(status, forKey: .status)
        }
    }
}

/// `start`'s result as `--json` reports it: the `StartResult` with the VM's name, which
/// `start --ephemeral` chose. `{"name": …, "outcome": …, "status": {...}}`.
public struct NamedStartResult: Encodable, Equatable, Sendable {
    public var name: String
    public var result: VMLifecycle.StartResult

    public init(name: String, result: VMLifecycle.StartResult) {
        self.name = name
        self.result = result
    }

    private enum CodingKeys: String, CodingKey { case name }

    public func encode(to encoder: any Encoder) throws {
        try result.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
    }
}

/// `{"outcome": "stopped" | "deleted" | "wasNotRunning"}`.
extension VMLifecycle.StopResult: Encodable {
    private enum CodingKeys: String, CodingKey { case outcome }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stopped: try container.encode("stopped", forKey: .outcome)
        case .deleted: try container.encode("deleted", forKey: .outcome)
        case .wasNotRunning: try container.encode("wasNotRunning", forKey: .outcome)
        }
    }
}

/// `{"outcome": "suspended" | "alreadySuspended" | "wasNotRunning", "savedStateBytes": n}`; the
/// size is absent if it wasn't running.
extension VMLifecycle.SuspendResult: Encodable {
    private enum CodingKeys: String, CodingKey { case outcome, savedStateBytes }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .suspended(let bytes):
            try container.encode("suspended", forKey: .outcome)
            try container.encode(bytes, forKey: .savedStateBytes)
        case .alreadySuspended(let bytes):
            try container.encode("alreadySuspended", forKey: .outcome)
            try container.encode(bytes, forKey: .savedStateBytes)
        case .wasNotRunning: try container.encode("wasNotRunning", forKey: .outcome)
        }
    }
}

/// `{"outcome": "discarded" | "deleted" | "notSuspended"}`.
extension VMLifecycle.DiscardResult: Encodable {
    private enum CodingKeys: String, CodingKey { case outcome }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .discarded: try container.encode("discarded", forKey: .outcome)
        case .deleted: try container.encode("deleted", forKey: .outcome)
        case .notSuspended: try container.encode("notSuspended", forKey: .outcome)
        }
    }
}
