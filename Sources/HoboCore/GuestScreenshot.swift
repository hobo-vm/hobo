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

    /// What to run in the desktop session of a guest running `os`; the PNG is its stdout.
    public static func command(for os: VMConfig.OS) -> [String] {
        switch os {
        case .macOS: macOSCommand
        case .linux: linuxCommand
        case .windows: WindowsGuest.screenshotCommand
        }
    }

    /// The macOS capture. `screencapture` can't write to
    /// stdout, so it goes through a temp file, which an interrupted capture cleans up too, exiting
    /// with the status a signal would give. Without the grant, `screencapture` still succeeds but
    /// leaves windows out, and the desktop it returns could pass for an app that never opened.
    public static let macOSCommand = ["sh", "-c", """
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

    /// The Linux capture, through the desktop portal's Screenshot API, since GNOME on Wayland lets no
    /// other client capture the screen. It first grants unsandboxed apps (app ID "") the portal's
    /// screenshot permission: without it, GNOME asks in a dialog that stays on screen, and later
    /// requests wait behind it (seen 2026-11-07 on Ubuntu 26.04). Granting each time covers clones
    /// and a grant someone withdrew. The portal saves the capture in `~/Pictures`, which this
    /// sends to stdout and removes.
    public static let linuxCommand = ["python3", "-c", """
        import os, sys
        from gi.repository import Gio, GLib

        bus = Gio.bus_get_sync(Gio.BusType.SESSION)

        def call(name, path, interface, method, signature, args):
            bus.call_sync(name, path, interface, method, GLib.Variant(signature, args), None, Gio.DBusCallFlags.NONE, -1, None)

        loop = GLib.MainLoop()
        response = []

        def on_response(connection, sender, path, interface, signal, parameters):
            response.extend(parameters.unpack())
            loop.quit()

        try:
            call("org.freedesktop.impl.portal.PermissionStore", "/org/freedesktop/impl/portal/PermissionStore",
                 "org.freedesktop.impl.portal.PermissionStore", "SetPermission", "(sbssas)",
                 ("screenshot", True, "screenshot", "", ["yes"]))
            token = "hobo%d" % os.getpid()
            sender = bus.get_unique_name()[1:].replace(".", "_")
            request = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)
            bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
                                 request, None, Gio.DBusSignalFlags.NONE, on_response)
            call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                 "org.freedesktop.portal.Screenshot", "Screenshot", "(sa{sv})",
                 ("", {"handle_token": GLib.Variant("s", token), "interactive": GLib.Variant("b", False)}))
        except GLib.Error as error:
            sys.exit("the screenshot portal failed: " + error.message)
        GLib.timeout_add_seconds(\(portalTimeoutSeconds), loop.quit)
        loop.run()
        if not response:
            sys.exit("the screenshot portal didn't answer within \(portalTimeoutSeconds) seconds")
        code, results = response
        if code != 0 or "uri" not in results:
            sys.exit("the screenshot portal refused the capture (response %d)" % code)
        path = Gio.File.new_for_uri(results["uri"]).get_path()
        try:
            with open(path, "rb") as capture:
                sys.stdout.buffer.write(capture.read())
        finally:
            os.remove(path)
        """]

    /// How long the Linux capture waits for the portal's answer, which takes well under a second.
    static let portalTimeoutSeconds = 30

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
