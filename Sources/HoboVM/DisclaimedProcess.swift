import Darwin
import Foundation

/// A child process spawned with responsibility disclaimed, so macOS's privacy checks (TCC, Local
/// Network) see the child as responsible for itself rather than hobo. Without it, the VM process,
/// which launchd runs as its own app, needs Local Network permission for every `ssh` it runs to
/// the guest network, and an ad-hoc build is a new app on every rebuild: each one asked again,
/// and until someone clicked Allow, every SSH probe failed silently (2026-11-02). `/usr/bin/ssh`
/// responsible for itself needs no such permission. Terminals launch shells the same way.
struct DisclaimedProcess: Sendable {
    let pid: pid_t

    /// What becomes of one of the child's standard streams.
    enum Stream {
        /// The same as this process's.
        case inherit
        case null
        case fileDescriptor(Int32)
    }

    /// Spawns `executable`; no other descriptors are inherited.
    static func spawn(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
        stdin: Stream = .null, stdout: Stream = .inherit, stderr: Stream = .inherit
    ) throws -> DisclaimedProcess {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        if let disclaim = setDisclaim { _ = disclaim(&attributes, 1) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, stream) in [(STDIN_FILENO, stdin), (STDOUT_FILENO, stdout), (STDERR_FILENO, stderr)] {
            switch stream {
            case .inherit: posix_spawn_file_actions_addinherit_np(&actions, target)
            case .null: posix_spawn_file_actions_addopen(&actions, target, "/dev/null", target == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
            case .fileDescriptor(let fd): posix_spawn_file_actions_adddup2(&actions, fd, target)
            }
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { env.forEach { free($0) } }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, executable, &actions, &attributes, argv, env)
        guard error == 0 else { throw VMError.spawnFailed(executable, String(cString: strerror(error))) }
        return DisclaimedProcess(pid: pid)
    }

    /// Waits for the child to exit, on a thread of its own, and returns its exit status (128 + the
    /// signal if one killed it, as a shell reports it).
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let pid = pid
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                let signal = status & 0x7f
                continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
            }
        }
    }

    func terminate() { kill(pid, SIGTERM) }

    /// `responsibility_spawnattrs_setdisclaim`, a libsystem export with no public header; looked up
    /// at run time so a system without it still spawns, just without disclaiming.
    private static let setDisclaim: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)
    }()
}
