import Foundation

/// Where this build of hobo lives. Installed, it is laid out as Homebrew lays out a formula, the CLI in
/// `bin/hobo` and its payloads in `share/hobo` beside it (`make install`, the Homebrew formula, and
/// `make sign`'s staged `.build/hobo`). A bare build such as `.build/debug/hobo` has neither, and reads
/// SwiftPM's resource bundle instead.
public enum HoboInstall {
    /// This process's executable, with symlinks resolved, so Homebrew's `bin/hobo` link gives the
    /// binary in its Cellar.
    public static var executable: URL { Bundle.main.executableURL!.resolvingSymlinksInPath() }

    /// The binary launchd runs as a VM process: this one, so a client and its VM processes are
    /// always the same build.
    public static var cli: URL { executable }

    /// The installed payloads, `share/hobo` beside the `bin` this executable is in, if there is one.
    public static var resources: URL? { resources(of: executable) }

    static func resources(of executable: URL) -> URL? {
        let bin = executable.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin" else { return nil }
        let share = bin.deletingLastPathComponent().appending(path: "share/hobo", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: share.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return share
    }
}
