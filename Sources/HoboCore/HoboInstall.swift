import Foundation

/// Where this build of hobo lives: inside Hobo.app, whose GUI is `Contents/MacOS/Hobo` and whose CLI
/// is `Contents/Helpers/hobo` (outside `MacOS`, so VM processes aren't taken for the app), or a bare
/// build such as `.build/debug/hobo`.
public enum HoboInstall {
    /// The name of the CLI inside the app's `Contents/Helpers`.
    public static let cliName = "hobo"

    /// This process's executable, with symlinks resolved, so `/usr/local/bin/hobo` gives the binary
    /// inside the app.
    public static var executable: URL { Bundle.main.executableURL!.resolvingSymlinksInPath() }

    /// The app's `Contents` directory, if `executable` is in its `MacOS` or `Helpers`.
    public static var contents: URL? { contents(of: executable) }

    static func contents(of executable: URL) -> URL? {
        let directory = executable.deletingLastPathComponent()
        let contents = directory.deletingLastPathComponent()
        guard ["MacOS", "Helpers"].contains(directory.lastPathComponent), contents.lastPathComponent == "Contents" else { return nil }
        return contents
    }

    /// The binary launchd runs as a VM process, so a client and its VM processes are always the same
    /// build: the app's CLI, or in a bare build the `hobo` beside this executable (itself, for the CLI).
    public static var cli: URL { cli(for: executable) }

    static func cli(for executable: URL) -> URL {
        if let contents = contents(of: executable) { return contents.appending(path: "Helpers/\(cliName)") }
        return executable.deletingLastPathComponent().appending(path: cliName)
    }

    /// The app's `Contents/Resources`, which holds what a bare build reads from SwiftPM's resource bundle.
    public static var resources: URL? { contents?.appending(path: "Resources", directoryHint: .isDirectory) }
}
