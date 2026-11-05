import Foundation
import PackagePlugin

/// Compiles the UEFI driver Windows guests boot with (`Firmware/WindowsBoot`) into Swift source, so
/// that `swift build` and `make` alike produce a complete binary with no compiled files in git.
@main
struct WindowsBootPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let source = context.package.directoryURL.appending(path: "Firmware/WindowsBoot")
        let output = context.pluginWorkDirectoryURL.appending(path: "WindowsBootFiles.swift")
        let scratch = context.pluginWorkDirectoryURL.appending(path: "efi")
        return [.buildCommand(
            displayName: "Compiling the Windows boot driver",
            executable: URL(filePath: "/bin/sh"),
            arguments: [source.appending(path: "build.sh").path, source.path, output.path, scratch.path],
            inputFiles: ["build.sh", "efi.h", "framebuffer.c", "loader.c"].map { source.appending(path: $0) },
            outputFiles: [output]
        )]
    }
}
