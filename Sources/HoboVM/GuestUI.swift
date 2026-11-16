import Foundation
import HoboControl
import HoboCore
import HoboUICore

extension AgentSession: UITransport {}

/// `hobo ui` for a Linux or Windows guest: `UIDriver` runs here in the VM process, over the guest's
/// backend (`hobo-ui-linux.py`, `hobo-ui-windows.exe`), which the agent fetches as the `ui` tool
/// and starts in the desktop session for the command's life (designs/hobo-ui-linux-windows.md).
/// A macOS guest runs the whole of `hobo ui` in `hobo-ui` instead.
enum GuestUI {
    /// The backend's command line in `platform`'s guest: the fetched tool, in the agent's run directory.
    static func backendCommand(for platform: any VMBundle.Type) -> [String] {
        platform.goos == "windows" ? [#"C:\ProgramData\Hobo\agent\hobo-ui.exe"#] : ["/usr/bin/python3", "/run/hobo-agent/hobo-ui"]
    }

    /// Runs the command `arguments` give, printing what `hobo-ui` would, and gives its exit status.
    static func run(
        _ arguments: [String], agent: GuestAgent, platform: any VMBundle.Type, refs: URL,
        onOutput: @escaping @Sendable (GuestStream, Data) -> Void
    ) async throws -> Int32 {
        let json = arguments.contains("--json")
        // Handed to the driver's thread and used nowhere else, so safe though ParsableCommand isn't Sendable.
        nonisolated(unsafe) let command: any ParsableCommand
        do {
            command = try HoboUI.parseAsRoot(arguments)
        } catch {
            onOutput(.stderr, Data((HoboUI.usageError(for: error) + "\n").utf8))
            return 64
        }
        if platform.goos == "windows", (try? Payloads.uiBackend("windows")) == nil {
            onOutput(.stderr, Data("hobo ui: this hobo was built without hobo ui's Windows backend; build it with make windows-ui\n".utf8))
            return 1
        }
        let session = try await agent.session(backendCommand(for: platform), gui: true, platform: platform, tool: "ui")
        // The driver blocks on the session's answers, so off the cooperative pool; cancelling the
        // task (the client hanging up) ends the session, which wakes it.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                Thread.detachNewThread {
                    continuation.resume(returning: runDriver(command, json: json, session: session, refs: refs, onOutput: onOutput))
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    private static func runDriver(
        _ command: any ParsableCommand, json: Bool, session: AgentSession, refs: URL,
        onOutput: @Sendable (GuestStream, Data) -> Void
    ) -> Int32 {
        func emit(_ output: (stdout: String, stderr: String)) {
            if !output.stdout.isEmpty { onOutput(.stdout, Data((output.stdout + "\n").utf8)) }
            if !output.stderr.isEmpty { onOutput(.stderr, Data((output.stderr + "\n").utf8)) }
        }
        do {
            let outcome = try UIDriver(backend: try RemoteBackend(transport: session), store: RefStore(directory: refs)).run(command)
            _ = try? session.close()
            emit(UIOutput.success(outcome, json: json))
            return 0
        } catch {
            _ = try? session.close()
            emit(UIOutput.failure(error, json: json, program: "hobo ui"))
            return 1
        }
    }
}
