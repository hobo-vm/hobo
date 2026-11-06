import Foundation
import HoboControl
import HoboCore

/// Runs a recipe's `[[provision]]` steps over key SSH: once each during `create`, and again on a
/// running VM with `hobo provision`.
public enum Provisioning {
    /// Runs every step in order; the first failure stops the rest.
    public static func run(_ recipe: Recipe, ssh: GuestSSH, log: @Sendable (String) -> Void) async throws {
        for (index, step) in recipe.provisioners.enumerated() {
            log("Provision step \(index + 1)/\(recipe.provisioners.count) (\(step.type.rawValue))")
            try await runStep(step, index: index, recipe: recipe, ssh: ssh)
        }
    }

    /// `hobo provision`: re-runs `recipeFile`'s steps on the running VM `name`, without rebuilding.
    /// The rest of the recipe is ignored, and the bundle keeps the recipe it was built from.
    public static func provision(
        _ name: String, recipeFile: URL, store: VMStore = .standard(), log: @Sendable (String) -> Void
    ) async throws -> ProvisionResult {
        let recipe = try Recipe.load(from: recipeFile)
        try recipe.checkFilesExist()
        let vm = try store.find(name)
        let channel = GuestChannel(store: store)
        let ssh = GuestSSH(host: try channel.ipAddress(vm.name), auth: try .forVM(bundle: vm.bundle, home: store.home))
        if recipe.provisioners.isEmpty { log("\(recipeFile.relativePath) has no [[provision]] steps") }
        // Steps can outlast an ephemeral VM's idle timeout, and their SSH never reaches its socket.
        try await channel.renewing(vm.name) { try await run(recipe, ssh: ssh, log: log) }
        return ProvisionResult(name: vm.name, steps: recipe.provisioners.count)
    }

    private static func runStep(_ step: Provisioner, index: Int, recipe: Recipe, ssh: GuestSSH) async throws {
        switch step.type {
        case .shell:
            let windows = recipe.os == .windows
            let remote = windows
                ? "\(WindowsGuest.temporaryDirectory)/hobo-provision-\(index + 1).ps1" : "/tmp/hobo-provision-\(index + 1).sh"
            if let inline = step.inline {
                let script = inline + "\n"
                try await ssh.upload(contents: windows ? WindowsGuest.powerShellScript(script) : script, to: remote)
            } else if let path = step.path {
                let file = recipe.resolve(path)
                if windows, let script = WindowsGuest.powerShellScript(try Data(contentsOf: file)) {
                    try await ssh.upload(contents: script, to: remote)
                } else {
                    try await ssh.upload(file, to: remote)
                }
            }
            let command = windows ? step.powerShellCommand(running: remote) : step.shellCommand(running: remote)
            try await ssh.check(command, what: "provision step \(index + 1)")
        case .file:
            guard let source = step.source, let destination = step.destination else { return }
            try await ssh.upload(recipe.resolve(source), to: destination)
        }
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
