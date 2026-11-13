import Foundation
import HoboCore

/// The files hobo carries for its guests: the agent for each OS, `hobo-ui`, the Windows boot driver
/// and install scripts, and the VM icons' signs. Installed, they are in `share/hobo` beside `bin/hobo`
/// (`HoboInstall.resources`); a bare build (`swift build`, `swift test`) reads SwiftPM's resource bundle.
public enum Payloads {
    public static let directory: URL = HoboInstall.resources ?? Bundle.module.resourceURL!

    public static func data(_ path: String) throws -> Data {
        let file = directory.appending(path: path)
        do {
            return try Data(contentsOf: file)
        } catch {
            throw VMError.missingPayload(file.path)
        }
    }

    /// hobo-agent for a guest OS, by Go's `GOOS`: `linux`, `darwin` or `windows`.
    static func agent(_ goos: String) throws -> Data { try data("hobo-agent-\(goos)") }
    static func hoboUI() throws -> Data { try data("hobo-ui") }
    /// `framebuffer.efi` or `loader.efi` (`Firmware/WindowsBoot`).
    static func windowsBoot(_ name: String) throws -> Data { try data(name) }
    /// A file of `Resources/Windows`: the install scripts and answer file.
    static func windows(_ name: String) throws -> Data { try data("Windows/\(name)") }
    /// A sign of `Resources/Signs`, by file name.
    static func sign(_ name: String) throws -> Data { try data("Signs/\(name)") }
}
