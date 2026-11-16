import Foundation
import HoboControl
import HoboCore
import Synchronization

/// Runs a recipe's `[[provision]]` steps in the guest: once each during `create`, and again on a
/// running VM with `hobo provision`, which its VM process runs.
public enum Provisioning {
    /// Runs every step in order; the first failure stops the rest. Progress goes to `log`, and the
    /// steps' output to `onOutput`, which by default is this process's own.
    public static func run(
        _ recipe: Recipe, shell: any GuestShell, log: @Sendable (String) -> Void,
        onOutput: @escaping @Sendable (GuestStream, Data) -> Void = inheritOutput
    ) async throws {
        for (index, step) in recipe.provisioners.enumerated() {
            log("Provision step \(index + 1)/\(recipe.provisioners.count) (\(step.type.rawValue))")
            try await runStep(step, index: index, recipe: recipe, shell: shell, onOutput: onOutput)
        }
    }

    /// Output passed on as this process's stdout and stderr.
    public static let inheritOutput: @Sendable (GuestStream, Data) -> Void = { stream, data in
        (stream == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(data)
    }

    /// `hobo provision`: re-runs `recipeFile`'s steps on the running VM `name`, without rebuilding.
    /// The rest of the recipe is ignored, and the bundle keeps the recipe it was built from. The VM
    /// process runs them (`provision(_:shell:onOutput:)`), and their output comes back here.
    public static func provision(
        _ name: String, recipeFile: URL, store: VMStore = .standard(), log: @Sendable (String) -> Void
    ) async throws -> ProvisionResult {
        // Checked here too, so a bad recipe fails before the VM process is asked.
        let recipe = try Recipe.load(from: recipeFile)
        try recipe.checkFilesExist()
        let vm = try store.find(name)
        if recipe.provisioners.isEmpty { log("\(recipeFile.relativePath) has no [[provision]] steps") }
        let status = try GuestChannel(store: store).provision(vm.name, recipeFile: recipeFile.absoluteURL) { stream, data in
            inheritOutput(stream, data)
        }
        if status != 0 { throw VMError.commandFailed("provisioning \(vm.name)", status) }
        return ProvisionResult(name: vm.name, steps: recipe.provisioners.count)
    }

    /// The VM process's side of `hobo provision`: progress lines go to the client as stderr, with
    /// the steps' own output. A failed step throws, which the client reports.
    static func provision(
        _ recipeFile: URL, shell: any GuestShell, onOutput: @escaping @Sendable (GuestStream, Data) -> Void
    ) async throws -> Int32 {
        let recipe = try Recipe.load(from: recipeFile)
        try recipe.checkFilesExist()
        try await run(recipe, shell: shell, log: { onOutput(.stderr, Data("\($0)\n".utf8)) }, onOutput: onOutput)
        return 0
    }

    private static func runStep(
        _ step: Provisioner, index: Int, recipe: Recipe, shell: any GuestShell,
        onOutput: @escaping @Sendable (GuestStream, Data) -> Void
    ) async throws {
        func upload(_ local: URL, to remote: String) async throws {
            let copy = GuestCopy(direction: .toGuest, sources: [local.path], destination: remote)
            let status = try await shell.copy(copy, onOutput: onOutput)
            if status != 0 { throw VMError.commandFailed("copying \(local.path) → \(remote)", status) }
        }
        func upload(contents: String, to remote: String) async throws {
            let local = FileManager.default.temporaryDirectory.appending(path: "hobo-\(UUID().uuidString)")
            try contents.write(to: local, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: local) }
            try await upload(local, to: remote)
        }
        switch step.type {
        case .shell:
            let windows = recipe.os == .windows
            let remote = windows
                ? "\(WindowsGuest.temporaryDirectory)/hobo-provision-\(index + 1).ps1" : "/tmp/hobo-provision-\(index + 1).sh"
            if let inline = step.inline {
                let script = inline + "\n"
                try await upload(contents: windows ? WindowsGuest.powerShellScript(script) : script, to: remote)
            } else if let path = step.path {
                let file = recipe.resolve(path)
                if windows, let script = WindowsGuest.powerShellScript(try Data(contentsOf: file)) {
                    try await upload(contents: script, to: remote)
                } else {
                    try await upload(file, to: remote)
                }
            }
            let command = windows ? step.powerShellCommand(running: remote) : step.shellCommand(running: remote)
            // The step's output can run to thousands of lines, so its last few go in the error.
            let tail = OutputTail()
            let status = try await shell.stream(command) { stream, data in
                tail.append(data)
                onOutput(stream, data)
            }
            if status != 0 { throw VMError.provisionFailed(step: index + 1, status: status, lastLines: tail.lines()) }
        case .file:
            guard let source = step.source, let destination = step.destination else { return }
            try await upload(recipe.resolve(source), to: destination)
        }
    }
}

/// The end of a command's output, stdout and stderr together, bounded however much it prints.
final class OutputTail: Sendable {
    static let keptBytes = 16 * 1024
    private let buffer = Mutex(Data())

    func append(_ data: Data) {
        buffer.withLock {
            $0.append(data)
            if $0.count > 2 * Self.keptBytes { $0 = Data($0.suffix(Self.keptBytes)) }
        }
    }

    /// The last `count` non-blank lines. A carriage return ends a line too, so a progress bar's
    /// redraws read as separate lines rather than one run together.
    func lines(_ count: Int = 10) -> [String] {
        let text = String(decoding: buffer.withLock { $0.suffix(Self.keptBytes) }, as: UTF8.self)
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }
}

/// `hobo provision --json`'s result: the VM and how many steps ran.
public struct ProvisionResult: Codable, Equatable, Sendable {
    public var name: String
    public var steps: Int

    public init(name: String, steps: Int) {
        self.name = name
        self.steps = steps
    }
}
