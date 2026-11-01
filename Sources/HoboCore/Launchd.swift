import Foundation

/// The per-user launchd domain (`gui/<uid>`), driven through `launchctl`. Every VM process runs
/// as a transient job there, and its job table is how Hobo knows which VMs are running.
public struct Launchd: Sendable {
    /// Every VM job's label starts with this.
    public static let labelPrefix = "com.hobo.vm."

    /// One row of `launchctl list`.
    public struct Job: Equatable, Sendable {
        public var label: String
        /// Set while the job's process runs.
        public var pid: Int32?
        /// The last run's exit status; negative for a signal (`-9` is SIGKILL).
        public var lastExitStatus: Int32

        public init(label: String, pid: Int32?, lastExitStatus: Int32) {
            self.label = label
            self.pid = pid
            self.lastExitStatus = lastExitStatus
        }
    }

    /// Runs `launchctl` with the given arguments, returning its exit status and combined output.
    public typealias Runner = @Sendable ([String]) throws -> (status: Int32, output: String)

    let launchctl: Runner

    public init(launchctl: @escaping Runner) { self.launchctl = launchctl }

    public static let system = Launchd { arguments in
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private var domain: String { "gui/\(getuid())" }

    /// Hobo's VM jobs, by label. Empty if `launchctl` can't be run.
    public func jobs() -> [String: Job] {
        guard let (status, output) = try? launchctl(["list"]), status == 0 else { return [:] }
        let jobs = Self.parseList(output).filter { $0.label.hasPrefix(Self.labelPrefix) }
        return Dictionary(jobs.map { ($0.label, $0) }) { first, _ in first }
    }

    /// Loads the job in `plist`; with `RunAtLoad` this starts it. Fails if the label is loaded.
    public func bootstrap(_ plist: URL) throws {
        let (status, output) = try launchctl(["bootstrap", domain, plist.path])
        guard status == 0 else { throw LaunchdError.failed("bootstrap \(plist.lastPathComponent)", status, output) }
    }

    /// Unloads `label`, killing its process if it still runs. A label that isn't loaded is fine.
    public func bootout(_ label: String) {
        _ = try? launchctl(["bootout", "\(domain)/\(label)"])
    }

    /// Sends `signal` (e.g. `SIGKILL`) to the job's process.
    public func kill(_ label: String, signal: String) throws {
        let (status, output) = try launchctl(["kill", signal, "\(domain)/\(label)"])
        guard status == 0 else { throw LaunchdError.failed("kill \(label)", status, output) }
    }

    /// Parses `launchctl list`: a `PID Status Label` header, then tab-separated rows where a job
    /// that isn't running has `-` for its PID.
    public static func parseList(_ text: String) -> [Job] {
        text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3, let status = Int32(fields[1]) else { return nil }
            return Job(label: String(fields[2]), pid: Int32(fields[0]), lastExitStatus: status)
        }
    }

    /// A transient agent: started when bootstrapped, never restarted, and not in
    /// `~/Library/LaunchAgents`, so nothing runs at login.
    public static func plist(label: String, arguments: [String], environment: [String: String], log: URL) throws -> Data {
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "EnvironmentVariables": environment,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }
}

public enum LaunchdError: Error, CustomStringConvertible {
    case failed(String, Int32, String)

    public var description: String {
        switch self {
        case .failed(let what, let status, let output):
            "launchctl \(what) failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
