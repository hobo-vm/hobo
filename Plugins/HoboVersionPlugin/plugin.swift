import Foundation
import PackagePlugin

/// Generates HoboCore's `generatedVersion` from the checkout's release tags (`scripts/version.sh`),
/// so that no source file states the version and a release is only a tag. It runs before every
/// build, since a new commit or tag changes the version without changing any file of the target.
@main
struct HoboVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let package = context.package.directoryURL
        let output = context.pluginWorkDirectoryURL.appending(path: "out")
        return [.prebuildCommand(
            displayName: "Generating hobo's version",
            executable: URL(filePath: "/bin/sh"),
            arguments: [package.appending(path: "scripts/version.sh").path, package.path, output.path],
            outputFilesDirectory: output
        )]
    }
}
