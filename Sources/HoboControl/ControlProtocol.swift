import Foundation
import HoboCore

/// The control-socket protocol between hobo clients (CLI, MCP) and a VM's `hobo _vm-run` process.
/// Each connection carries one request, as a line of JSON. Most get one line of JSON back;
/// `exec`, `copy` and `remove` stream `output` lines and end with `exited`.
public enum ControlProtocol {
    /// Bumped on any incompatible change. A VM process refuses other versions, since a client and
    /// a VM process started by an older `hobo` can both be around after an upgrade.
    /// Adding a request or an optional field isn't incompatible: an older VM process answers a
    /// request it doesn't know with an error.
    public static let version = 2
}

public enum ControlRequest: Codable, Equatable, Sendable {
    /// Asks how the VM process is doing. Looking isn't using: this alone doesn't count as activity,
    /// or a `hobo list` left polling would keep every forgotten ephemeral VM alive.
    case status
    /// `status` from a client that is about to use the VM, e.g. `hobo ip` before its own SSH.
    case renew
    /// Starts the stop sequence and replies at once; the VM process exits when the VM is off.
    case stop(force: Bool)
    /// Runs a command in the guest, without stdin or a TTY: `output` lines, then `exited`.
    /// The arguments are quoted for the guest user's login shell (`VMBundle.agentCommand`); with
    /// `gui`, the command runs in that user's desktop session.
    case exec(command: [String], gui: Bool = false)
    /// `hobo ui`: runs hobo-ui in a macOS guest's desktop session with these arguments, which the
    /// client has checked (`HoboUI`): `output` lines, then `exited`.
    case ui(arguments: [String])
    /// Copies between host paths and the guest: the copy's messages as `output` lines, then `exited`.
    case copy(GuestCopy)
    /// `hobo rm`: removes guest paths, as the guest user: what fails as `output` lines, then `exited`.
    case remove(GuestRemove)
    /// `hobo provision`: runs the `[[provision]]` steps of the recipe at this absolute host path,
    /// streaming progress and the steps' output as `output` lines, then `exited`.
    case provision(recipeFile: String)
    /// Pauses the VM and saves its state, answering once the state is saved (or with what stopped
    /// it, leaving the VM running); the VM process then powers the VM off and exits.
    case suspend
    /// Pauses the VM, saves its state and clones its disk to the snapshot `tag`, and resumes it,
    /// answering once it is running again (or with what stopped it).
    case snapshot(tag: String)
    /// Shows the VM's window, creating it the first time, and brings it to the front: activating
    /// hobo, as a person asking for it wants. With `activate` false (integration tests) it opens
    /// behind every other window, out of the Dock, taking nothing from whoever is at the Mac.
    case view(activate: Bool = true)

    /// Whether this request holds the VM's idle timeout while it runs: all but `status`, which isn't
    /// use, and `renew`, which only restarts it.
    public var holdsIdleTimeout: Bool { self != .status && self != .renew }
}

public enum ControlResponse: Codable, Equatable, Sendable {
    case status(VMRunStatus)
    case accepted
    case error(String)
    /// A chunk of a streaming request's output (base64 in the JSON).
    case output(GuestStream, Data)
    /// Ends a streaming request with the guest command's (or scp's) exit status.
    case exited(Int32)
}

public enum GuestStream: String, Codable, Equatable, Sendable {
    case stdout
    case stderr
}

/// What a VM process reports about itself.
public struct VMRunStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Booting, until the guest's agent answers.
        case starting
        case running
        case stopping
    }

    public var state: State
    public var pid: Int32
    /// What the VM process is doing now, e.g. which stop step it is on.
    public var detail: String?
    public var ipAddress: String?
    /// Whether the VM's window is showing (`hobo view`, `start --gui`) rather than hidden or never
    /// opened. VM processes from before it existed don't send it.
    @MissingAsFalse public var windowShown: Bool
    /// The idle timeout this run has, if it has one: only an ephemeral VM does (decision 18).
    public var idleTimeoutSeconds: Int?
    /// What is left of it, rounded up. Absent while it isn't counting: until the boot sequence ends,
    /// while a request is running or the window is showing, and once the VM is stopping.
    public var idleSecondsRemaining: Int?

    public init(
        state: State, pid: Int32, detail: String? = nil, ipAddress: String? = nil, windowShown: Bool = false,
        idleTimeoutSeconds: Int? = nil, idleSecondsRemaining: Int? = nil
    ) {
        self.state = state
        self.pid = pid
        self.detail = detail
        self.ipAddress = ipAddress
        self.windowShown = windowShown
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.idleSecondsRemaining = idleSecondsRemaining
    }
}

/// The wire form of a request, carrying the client's protocol version.
struct ControlEnvelope: Codable, Equatable {
    var version: Int
    var request: ControlRequest
}

public enum ControlError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case unreachable(String, String)
    case badMessage(String)
    /// A socket system call failed.
    case system(String)

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            "socket path \(path) is longer than the \(ControlSocket.maxPathBytes) bytes a Unix socket allows (shorten HOBO_HOME or the VM name)"
        case .unreachable(let path, let reason): "can't reach the VM process at \(path): \(reason)"
        case .badMessage(let reason): "bad control message: \(reason)"
        case .system(let reason): "control socket: \(reason)"
        }
    }
}
