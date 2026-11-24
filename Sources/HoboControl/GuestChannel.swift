import Foundation
import HoboCore

/// Reaches a running VM's guest on behalf of a client (the CLI, MCP): its IP, and `exec`, `cp` and
/// `provision`, which the VM process runs through the guest's agent (or SSH) and streams back
/// (decision 15).
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

    /// Runs `command` in the guest, in its desktop session if `gui`, and returns its exit status.
    public func exec(_ name: String, command: [String], gui: Bool = false, onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        try stream(.exec(command: command, gui: gui), name: name, onOutput: onOutput)
    }

    /// `hobo ui`: runs hobo-ui in a macOS guest with `arguments`, or the driver in the VM process for
    /// another guest, and returns its exit status. A command that fails, or can't run, goes in the
    /// home's `UIFailureLog` with what it printed.
    public func ui(_ name: String, arguments: [String], onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        let failures = UIFailureLog(file: store.home.uiFailures)
        var printed = Data()
        do {
            let status = try uiUnrecorded(name, arguments: arguments) { stream, data in
                // Both streams, in the order they came.
                printed += data
                try onOutput(stream, data)
            }
            if status != 0 { try? failures.record(vm: name, arguments: arguments, result: "exit \(status)", output: printed) }
            return status
        } catch {
            try? failures.record(vm: name, arguments: arguments, result: "\(error)", output: printed)
            throw error
        }
    }

    private func uiUnrecorded(_ name: String, arguments: [String], onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        let (vm, _) = try runningJob(name)
        let config = try VMConfig.load(from: vm.bundle.appending(path: VMStore.configFile))
        if let major = config.macOSMajor, major < Conventions.uiToolMinimumMajor {
            throw GuestChannelError.uiNeedsNewerGuest(vm.name, config.osDescription)
        }
        return try stream(.ui(arguments: arguments), name: name, onOutput: onOutput)
    }

    /// Captures the guest's screen from inside its desktop session (decision 17).
    public func screenshot(_ name: String) throws -> GuestScreenshot {
        // Says that a VM is being built or stopped, before its config.json is read.
        let (vm, _) = try runningJob(name)
        var png = Data()
        var errors = Data()
        let config = try VMConfig.load(from: vm.bundle.appending(path: VMStore.configFile))
        let status = try exec(name, command: GuestScreenshot.command(for: config.os), gui: true) { stream, data in
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

    /// Where `subject` is on the guest's screen, asked of `hobo ui` there, for `cropped(to:)`.
    public func screenshotCrop(_ name: String, around subject: ScreenshotSubject) throws -> ScreenshotCrop {
        var answer = Data()
        var errors = Data()
        // hobo ui prints a failure as JSON too, so its exit status says nothing more.
        _ = try ui(name, arguments: subject.uiArguments) { stream, data in
            switch stream {
            case .stdout: answer += data
            case .stderr: errors += data
            }
        }
        return try subject.crop(fromUIOutput: answer, errors: errors)
    }

    /// Copies and returns its exit status; the copy's messages arrive as output.
    public func copy(_ name: String, _ copy: GuestCopy, onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        try stream(.copy(copy), name: name, onOutput: onOutput)
    }

    /// Removes guest paths and returns the exit status; what couldn't be removed arrives as output.
    public func remove(_ name: String, _ remove: GuestRemove, onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        try stream(.remove(remove), name: name, onOutput: onOutput)
    }

    /// Runs the `[[provision]]` steps of the recipe at `recipeFile` in the guest; progress and the
    /// steps' output arrive as output.
    public func provision(_ name: String, recipeFile: URL, onOutput: (GuestStream, Data) throws -> Void) throws -> Int32 {
        try stream(.provision(recipeFile: recipeFile.path), name: name, onOutput: onOutput)
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
        // Its VM runs inside `hobo create` until the build is done, with no socket to reach it by.
        if case .building = vm.status { throw VMStoreError.busy(vm.name, reason: "being built") }
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

/// `hobo exec --json`, `hobo cp --json` and `hobo rm --json`: the guest command's (or the copy's
/// or removal's) exit status. Its output went to stderr, keeping stdout for this.
public struct GuestCommandResult: Codable, Equatable, Sendable {
    public var exitStatus: Int32

    public init(exitStatus: Int32) { self.exitStatus = exitStatus }
}

public enum GuestChannelError: Error, Equatable, CustomStringConvertible {
    case notRunning(String)
    case noIPAddress(String, String?)
    case screenshotFailed(String, String)
    case uiNeedsNewerGuest(String, String)

    public var description: String {
        switch self {
        case .notRunning(let name): "\(name) is not running (hobo start \(name))"
        case .noIPAddress(let name, let detail): "\(name) has no IP yet\(detail.map { " (\($0))" } ?? "")"
        case .screenshotFailed(let name, let reason): "can't screenshot \(name): \(reason)"
        case .uiNeedsNewerGuest(let name, let os):
            "hobo ui needs a guest on macOS \(Conventions.uiToolMinimumMajor) or later, and \(name) runs \(os); exec --gui and screenshot work there"
        }
    }
}
