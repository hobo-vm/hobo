import Foundation

/// A PNG of a guest's screen, captured from inside its desktop session (`GuestChannel.screenshot`).
public struct GuestScreenshot: Equatable, Sendable {
    /// The VM's name as stored.
    public var name: String
    public var png: Data

    public init(name: String, png: Data) {
        self.name = name
        self.png = png
    }

    public static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// What to run in the desktop session of a guest running `os`.
    public static func command(for os: VMConfig.OS) -> [String] {
        os == .windows ? WindowsGuest.screenshotCommand : command
    }

    /// Run in the guest's desktop session; the PNG is its stdout. `screencapture` can't write to
    /// stdout, so it goes through a temp file, which an interrupted capture cleans up too, exiting
    /// with the status a signal would give. Without the grant, `screencapture` still succeeds but
    /// leaves windows out, and the desktop it returns could pass for an app that never opened.
    public static let command = ["sh", "-c", """
        f=$(mktemp /tmp/hobo-screenshot.XXXXXX) || exit 1
        trap 'rm -f "$f"' EXIT
        trap 'exit 143' HUP INT TERM
        granted=$(osascript -l JavaScript -e '\(GUITestingGrants.bindScreenCapturePreflight); $.CGPreflightScreenCaptureAccess()')
        if [ "$granted" != true ]; then
          echo "Screen Recording isn't granted; build this VM from a recipe with [gui_testing]" >&2
          exit 1
        fi
        screencapture -x -t png "$f" && cat "$f"
        """]

    /// Writes the PNG to `path`, replacing what's there. With no path it goes in `directory` under a
    /// name of its own, `<vm>-<timestamp>.png`, numbered if that is taken, so a session's
    /// screenshots never replace each other. Returns where it went.
    public func save(
        to path: String?, in directory: URL = .currentDirectory(), date: Date = .now
    ) throws -> URL {
        guard let path else { return try saveUnderANewName(in: directory, date: date) }
        // Not `URL(filePath:relativeTo:)`: it drops the base's last component when the base has
        // no trailing slash, which would write beside `directory` rather than in it.
        let file = (path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)).standardizedFileURL
        try png.write(to: file)
        return file
    }

    private func saveUnderANewName(in directory: URL, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(name)-\(formatter.string(from: date))"
        var attempt = 1
        while true {
            let file = directory.appending(path: attempt == 1 ? "\(stem).png" : "\(stem)-\(attempt).png").standardizedFileURL
            do {
                try png.write(to: file, options: .withoutOverwriting)
                return file
            } catch CocoaError.fileWriteFileExists {
                attempt += 1
            }
        }
    }
}

/// `hobo screenshot --json`.
public struct ScreenshotResult: Codable, Equatable, Sendable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}
