import Foundation
import HoboCore

/// The control-socket protocol between hobo clients (CLI, MCP) and a VM's `hobo _vm-run` process.
/// Each connection carries one request, as a line of JSON. Most get one line of JSON back;
/// `exec` and `copy` stream `output` lines and end with `exited`.
public enum ControlProtocol {
    /// Bumped on any incompatible change. A VM process refuses other versions, since a client and
    /// a VM process started by an older `hobo` can both be around after an upgrade.
    /// Adding a request or an optional field isn't incompatible: an older VM process answers a
    /// request it doesn't know with an error.
    public static let version = 2
}

public enum ControlRequest: Codable, Equatable, Sendable {
    case status
    /// Starts the stop sequence and replies at once; the VM process exits when the VM is off.
    case stop(force: Bool)
    /// Runs a command in the guest over SSH, without stdin or a TTY: `output` lines, then `exited`.
    /// The arguments are shell-quoted and run by the guest user's login shell.
    case exec(command: [String])
    /// Runs scp between host paths and the guest: scp's output as `output` lines, then `exited`.
    case copy(GuestCopy)
    /// Pauses the VM and saves its state, answering once the state is saved (or with what stopped
    /// it, leaving the VM running); the VM process then powers the VM off and exits.
    case suspend
    /// Shows the VM's window, creating it the first time, and brings it to the front.
    case view
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
        /// Booting, until the guest answers SSH.
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

    public init(state: State, pid: Int32, detail: String? = nil, ipAddress: String? = nil, windowShown: Bool = false) {
        self.state = state
        self.pid = pid
        self.detail = detail
        self.ipAddress = ipAddress
        self.windowShown = windowShown
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
