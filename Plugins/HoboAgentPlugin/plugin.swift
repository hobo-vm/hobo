import Foundation
import PackagePlugin

/// Builds the guest agent (`Agent`, Go) for each guest OS. The binaries are outputs of the build, so
/// SwiftPM copies them into HoboVM's resources (`Payloads`), with no compiled files in git.
@main
struct HoboAgentPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let source = context.package.directoryURL.appending(path: "Agent")
        let output = context.pluginWorkDirectoryURL.appending(path: "out")
        let scratch = context.pluginWorkDirectoryURL.appending(path: "agent")
        let inputs = try FileManager.default.contentsOfDirectory(atPath: source.path)
            .filter { ($0.hasSuffix(".go") && !$0.hasSuffix("_test.go")) || $0 == "go.mod" || $0 == "build.sh" }
            .sorted()
            .map { source.appending(path: $0) }
        return [.buildCommand(
            displayName: "Building hobo-agent",
            executable: URL(filePath: "/bin/sh"),
            arguments: [source.appending(path: "build.sh").path, source.path, output.path, scratch.path],
            inputFiles: inputs,
            outputFiles: ["linux", "darwin", "windows"].map { output.appending(path: "hobo-agent-\($0)") }
        )]
    }
}
