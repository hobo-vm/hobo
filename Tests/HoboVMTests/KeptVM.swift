import Foundation
import HoboCore
import HoboVM
import Testing

/// The kept VMs the guest tests clone (`macos27`, `ubuntu26`, `windows11` by default, built from
/// `recipes/` by `make test-vms`): everything that doesn't depend on how a VM was built runs on a
/// clone of one, so it needn't wait for a build. Each is named by a variable that
/// `make integration-test` sets; set it empty to leave that guest out.
enum KeptVM {
    static let macOS = "HOBO_MACOS_VM"
    static let linux = "HOBO_LINUX_VM"
    static let windows = "HOBO_WINDOWS_VM"

    /// Whether the tests on the kept VM `variable` names run: with HOBO_INTEGRATION, unless it is set empty.
    static func enabled(_ variable: String) -> Bool {
        integrationEnabled && environment[variable] != ""
    }

    /// The kept VM `variable` names, which must be in the real store: a missing one fails the test
    /// rather than leave its guest untested.
    static func source(_ variable: String) throws -> String {
        let source = try #require(environment[variable], "\(variable) names the VM to clone; make integration-test sets it")
        try #require(
            (try? VMStore.standard().find(source)) != nil,
            "\(variable) names \(source), which isn't in \(VMStore.standard().directory.path): make test-vms builds it"
        )
        return source
    }

    /// Clones the kept VM `variable` names from the real store to `name` in the test's own store
    /// `vms` (whose launchd jobs are kept apart from real ones), and writes its recipe to
    /// `work/Hobo.toml`, as a test that built it would have. Returns the clone's config.
    @discardableResult
    static func clone(_ variable: String, to name: String, vms: URL, work: URL) throws -> VMConfig {
        let source = try source(variable)
        let clone = try VMStore(directory: vms).cloneVM(source, from: .standard(), to: name) { _ in }
        try FileManager.default.copyItem(
            at: clone.bundle.appending(path: VMStore.recipeFile), to: work.appending(path: "Hobo.toml")
        )
        return try VMConfig.load(from: clone.bundle.appending(path: VMStore.configFile))
    }
}
