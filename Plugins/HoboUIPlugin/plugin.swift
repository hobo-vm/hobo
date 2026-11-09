import Foundation
import PackagePlugin

/// Copies `hobo-ui`, the macOS guests' accessibility driver, into HoboVM's resources (`Payloads`), as
/// `HoboAgentPlugin` does the agent. Host and guest are both arm64 macOS, so the tool SwiftPM builds
/// for the host is the guest's binary.
@main
struct HoboUIPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "hobo-ui").url
        let output = context.pluginWorkDirectoryURL.appending(path: "out/hobo-ui")
        // Backticks, not $(…) or ${…}, which the build system would take for its own settings.
        return [.buildCommand(
            displayName: "Copying hobo-ui",
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", #"mkdir -p "`dirname "$2"`" && cp "$1" "$2""#, "copy", tool.path, output.path],
            inputFiles: [tool],
            outputFiles: [output]
        )]
    }
}
