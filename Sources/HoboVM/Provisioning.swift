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
        let ip = try GuestChannel(store: store).ipAddress(vm.name)
        let ssh = GuestSSH(host: ip, auth: try .forVM(bundle: vm.bundle, home: store.home))
        if recipe.provisioners.isEmpty { log("\(recipeFile.relativePath) has no [[provision]] steps") }
        try await run(recipe, ssh: ssh, log: log)
        return ProvisionResult(name: vm.name, steps: recipe.provisioners.count)
    }

    private static func runStep(_ step: Provisioner, index: Int, recipe: Recipe, ssh: GuestSSH) async throws {
        switch step.type {
        case .shell:
            let remote = "/tmp/hobo-provision-\(index + 1).sh"
            if let inline = step.inline {
                try await ssh.upload(contents: inline + "\n", to: remote)
            } else if let path = step.path {
                try await ssh.upload(recipe.resolve(path), to: remote)
            }
            try await ssh.check(step.shellCommand(running: remote), what: "provision step \(index + 1)")
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
