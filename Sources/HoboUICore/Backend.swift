import CoreGraphics
import Foundation

/// What `UIDriver` needs of a guest's accessibility and input: macOS's AX and CGEvents in
/// `hobo-ui`, or a Linux (AT-SPI) or Windows (UI Automation) guest's backend spoken to from the
/// VM process (designs/hobo-ui-linux-windows.md). Coordinates are the platform's own (points on
/// macOS); `scale` converts them to screenshot pixels. Elements read their attributes as they
/// were when fetched; `current` reads them again.
public protocol UIBackend {
    associatedtype Element: AccessibleElement

    var platform: UIPlatform { get }
    /// Screenshot pixels per unit of the platform's coordinates.
    var scale: PixelScale { get }
    /// The screen, in the platform's coordinates.
    var screen: CGRect { get }

    /// Throws when the guest won't let the backend drive its apps, saying why.
    func checkAccess() throws

    /// The apps with windows, for `--app`.
    func apps() throws -> [RunningApp]
    /// The app the focused window belongs to.
    func frontmostApp() throws -> RunningApp?
    /// The app's element, whose children are its windows (and menu bar).
    func root(of app: RunningApp) throws -> Element
    /// The app an element belongs to.
    func app(of element: Element) -> AppIdentity

    /// The element's attributes now; nil once it's gone.
    func current(_ element: Element) -> ElementAttributes?
    /// The element's parent; nil at its app.
    func parent(of element: Element) -> Element?
    func same(_ a: Element, _ b: Element) -> Bool
    /// The element a click at `point` would reach, whichever app it's in.
    func element(at point: CGPoint) -> Element?

    /// Whether `element`, found over what a click was meant for, is the cover the system keeps
    /// over the desktop while it logs in, which goes by itself: `UIDriver` waits for it rather
    /// than fail the click.
    func coversWhileLoggingIn(_ element: Element) -> Bool

    /// Brings the element's app forward and raises its window, waiting a moment for it to take.
    func bringForward(_ element: Element, of app: RunningApp)
    /// The on-screen windows over `area`, as stacked now; `UIDriver` waits for them to stop
    /// changing before it clicks.
    func windows(over area: CGRect) -> [WindowState]
    /// A pop-up, context or toolbar menu that is open, described for a warning, when `point`
    /// isn't in it: a click there would go to closing it.
    func openMenu(notAt point: CGPoint) -> String?

    /// The element's default action (AXPress, `do_action(0)`, Invoke).
    func press(_ element: Element) throws
    /// Asks the element's scroll areas to show it; false when it can't.
    func scrollToVisible(_ element: Element) -> Bool

    /// The app's menu bar; nil when it has none.
    func menuBar(of root: Element) -> Element?
    /// What a menu bar or menu item opens: its items, opening it first where the platform must.
    func menuItems(of element: Element) -> [Element]
    func menuItem(_ element: Element) -> MenuItemInfo

    func click(at point: CGPoint, right: Bool, count: Int, modifiers: [Modifier])
    func drag(from start: CGPoint, to end: CGPoint, modifiers: [Modifier])
    func scroll(at point: CGPoint, _ direction: HoboUI.ScrollDirection, lines: Int)
    /// One scroll of `distance` units, as a trackpad scrolls; by lines where there is no such thing.
    func scroll(at point: CGPoint, _ direction: HoboUI.ScrollDirection, distance: Double)
    func key(_ spec: KeySpec)
    func type(_ text: String)
    func pause(_ seconds: Double)
}

/// An app `--app` can name.
public struct RunningApp: Equatable, Sendable {
    public var identity: AppIdentity
    /// What else names it exactly, besides its ID and name: a Windows app's exe name beside its AUMID.
    public var aliases: [String]

    public init(identity: AppIdentity, aliases: [String] = []) {
        self.identity = identity
        self.aliases = aliases
    }

    /// The app `spec` names among `apps` (`--app`): `pid:<n>`, else an ID or alias, else a name,
    /// ignoring case; nil `spec` is the frontmost. Several matches fail with each of them.
    public static func find(_ spec: String?, in apps: [RunningApp], frontmost: RunningApp?) throws -> RunningApp {
        guard let spec else {
            guard let frontmost else { throw UIError.failed("no app is frontmost; give --app") }
            return frontmost
        }
        if spec.hasPrefix("pid:") {
            guard let pid = Int32(spec.dropFirst(4)), let app = apps.first(where: { $0.identity.pid == pid }) else {
                throw UIError.noApp(spec)
            }
            return app
        }
        func named(_ text: String?) -> Bool { text?.caseInsensitiveCompare(spec) == .orderedSame }
        let byID = apps.filter { named($0.identity.id) || $0.aliases.contains(where: named) }
        let matches = byID.isEmpty ? apps.filter { named($0.identity.name) } : byID
        guard let first = matches.first else { throw UIError.noApp(spec) }
        guard matches.count == 1 else {
            let names = matches.map { "\($0.identity.name) (\($0.identity.id ?? "no ID"), pid \($0.identity.pid))" }
            throw UIError.failed("\(spec) matches \(matches.count) apps: \(names.joined(separator: "; ")); give --app pid:<n>")
        }
        return first
    }
}

/// A window as `UIBackend.windows(over:)` sees it: what an animation changes every frame.
public struct WindowState: Equatable, Sendable {
    public var id: Int
    public var bounds: CGRect
    public var alpha: Double

    public init(id: Int, bounds: CGRect, alpha: Double = 1) {
        self.id = id
        self.bounds = bounds
        self.alpha = alpha
    }
}

/// A menu item as `menu` lists it.
public struct MenuItemInfo: Codable, Equatable, Sendable {
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    /// In `key`'s syntax, e.g. cmd+shift+s.
    public var shortcut: String?
    public var submenu: Bool

    public init(title: String, enabled: Bool, checked: Bool, shortcut: String?, submenu: Bool) {
        self.title = title
        self.enabled = enabled
        self.checked = checked
        self.shortcut = shortcut
        self.submenu = submenu
    }

    public var line: String {
        if title.isEmpty { return "---" }
        var parts = ["\"\(title)\""]
        if let shortcut { parts.append(shortcut) }
        if submenu { parts.append(">") }
        if !enabled { parts.append("disabled") }
        if checked { parts.append("checked") }
        return parts.joined(separator: " ")
    }
}

/// What a command prints: `text`, or with `--json` the rest.
public struct Outcome: Encodable {
    public var text: String
    public var element: SnapshotNode?
    public var items: [MenuItemInfo]?
    public var snapshot: AppSnapshot?
    /// A menu open away from where a click went (or `at`'s point), which it would go to closing.
    public var openMenu: String?

    public init(text: String, element: SnapshotNode? = nil, items: [MenuItemInfo]? = nil, snapshot: AppSnapshot? = nil, openMenu: String? = nil) {
        self.text = text
        self.element = element
        self.items = items
        self.snapshot = snapshot
        self.openMenu = openMenu
    }

    enum CodingKeys: String, CodingKey { case text = "message", element, items, snapshot, openMenu }
}

public enum UIError: Error, CustomStringConvertible {
    case noAccess(String)
    case noApp(String)
    case failed(String)
    case timedOut(String, AppSnapshot?)

    public var description: String {
        switch self {
        case .noAccess(let why): why
        case .noApp(let spec): "no running app matches \(spec)"
        case .failed(let message): message
        case .timedOut(let message, _): message
        }
    }
}

/// How `hobo ui` prints a command's result or failure, in the guest (`hobo-ui`) or the VM process.
public enum UIOutput {
    struct Failure: Encodable {
        var error: String
        var snapshot: AppSnapshot?
    }

    /// The outcome's text, or its JSON.
    public static func success(_ outcome: Outcome, json: Bool) -> (stdout: String, stderr: String) {
        (json ? encode(outcome) : outcome.text, "")
    }

    /// The failure as `program: error` (and a timeout's snapshot), or as JSON with the error on
    /// stderr too, so a pipe into jq doesn't hide it.
    public static func failure(_ error: Error, json: Bool, program: String) -> (stdout: String, stderr: String) {
        var snapshot: AppSnapshot?
        if case UIError.timedOut(_, let taken) = error { snapshot = taken }
        if json { return (encode(Failure(error: String(describing: error), snapshot: snapshot)), "Error: \(error)") }
        return (snapshot?.text ?? "", "\(program): \(error)")
    }

    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
