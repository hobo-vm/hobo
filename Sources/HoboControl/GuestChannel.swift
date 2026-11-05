import Foundation
import HoboCore

/// Reaches a running VM's guest on behalf of a client (the CLI, later MCP): its IP, and `exec` and
/// `cp`, which the VM process runs over its SSH and streams back (decision 15).
public struct GuestChannel: Sendable {
    public var store: VMStore

    public init(store: VMStore = .standard()) {
        self.store = store
    }

    /// The guest's IP as its VM process knows it (its DHCP lease).
    public func ipAddress(_ name: String) throws -> String {
        try address(name).ipAddress
    }

    /// The VM's name as stored and its guest's IP, as `hobo ip --json` reports them. Whoever asks is
    /// about to use the guest, so this renews its idle timeout; SSH itself never reaches the socket.
    public func address(_ name: String) throws -> GuestAddress {
        let (vm, job) = try runningJob(name)
        let status = try ControlClient.renew(at: job.socket)
        guard let ip = status.ipAddress else { throw GuestChannelError.noIPAddress(vm.name, status.detail) }
        return GuestAddress(name: vm.name, ipAddress: ip)
    }

    /// Runs `body`, which works over its own SSH, renewing the idle timeout of the VM with this stored
    /// name until it ends. A renewal that fails isn't `body`'s failure: if the VM has gone, its SSH says so.
    public func renewing(_ name: String, every interval: Duration = .seconds(1), while body: () async throws -> Void) async throws {
        let socket = store.job(for: name).socket
        let renewals = Task {
            while true {
                try await Task.sleep(for: interval) // Throws once cancelled, which ends the renewals.
                _ = try? await ControlClient.renew(at: socket)
            }
        }
        defer { renewals.cancel() }
        try await body()
    }

    /// Runs `command` in the guest, in its desktop session if `gui`, and returns its exit status.
    public func exec(_ name: String, command: [String], gui: Bool = false, onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        try stream(.exec(command: command, gui: gui), name: name, onOutput: onOutput)
    }

    /// Captures the guest's screen from inside its desktop session (decision 17).
    public func screenshot(_ name: String) throws -> GuestScreenshot {
        let vm = try store.find(name)
        var png = Data()
        var errors = Data()
        let status = try exec(name, command: GuestScreenshot.command, gui: true) { stream, data in
            switch stream {
            case .stdout: png += data
            case .stderr: errors += data
            }
        }
        guard status == 0 else {
            let reason = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestChannelError.screenshotFailed(vm.name, reason.isEmpty ? "the capture exited with status \(status)" : reason)
        }
        // The script's temp file starts out empty, so a `screencapture` that succeeds without writing sends nothing.
        guard !png.isEmpty else { throw GuestChannelError.screenshotFailed(vm.name, "the capture came back empty") }
        guard png.starts(with: GuestScreenshot.pngSignature) else {
            throw GuestChannelError.screenshotFailed(vm.name, "the guest's output isn't a PNG (does a shell startup file print something?)")
        }
        return GuestScreenshot(name: vm.name, png: png)
    }

    /// Copies with scp and returns its exit status; scp's messages arrive as output.
    public func copy(_ name: String, _ copy: GuestCopy, onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        try stream(.copy(copy), name: name, onOutput: onOutput)
    }

    private func stream(_ request: ControlRequest, name: String, onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        let (vm, job) = try runningJob(name)
        let response = try ControlClient.stream(request, to: job.socket, onOutput: onOutput)
        switch response {
        case .exited(let status): return status
        case .error(let message): throw LifecycleError.refused(vm.name, message)
        default: throw ControlError.badMessage("expected an exit status, got \(response)")
        }
    }

    private func runningJob(_ name: String) throws -> (VMStore.VM, VMJob) {
        let vm = try store.find(name)
        guard vm.job?.pid != nil else { throw GuestChannelError.notRunning(vm.name) }
        return (vm, store.job(for: vm.name))
    }
}

/// `hobo ip --json`.
public struct GuestAddress: Codable, Equatable, Sendable {
    public var name: String
    public var ipAddress: String

    public init(name: String, ipAddress: String) {
        self.name = name
        self.ipAddress = ipAddress
    }
}

/// `hobo exec --json` and `hobo cp --json`: the guest command's (or scp's) exit status. Its output
/// went to stderr, keeping stdout for this.
public struct GuestCommandResult: Codable, Equatable, Sendable {
    public var exitStatus: Int32

    public init(exitStatus: Int32) { self.exitStatus = exitStatus }
}

public enum GuestChannelError: Error, Equatable, CustomStringConvertible {
    case notRunning(String)
    case noIPAddress(String, String?)
    case screenshotFailed(String, String)

    public var description: String {
        switch self {
        case .notRunning(let name): "\(name) is not running (hobo start \(name))"
        case .noIPAddress(let name, let detail): "\(name) has no IP yet\(detail.map { " (\($0))" } ?? "")"
        case .screenshotFailed(let name, let reason): "can't screenshot \(name): \(reason)"
        }
    }
}
