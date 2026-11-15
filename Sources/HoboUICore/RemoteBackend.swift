import CoreGraphics
import Foundation

/// How `RemoteBackend` reaches a guest's backend: one JSON request line in, one JSON answer line
/// out (`AgentSession` in the VM process).
public protocol UITransport: AnyObject {
    func send(_ line: Data) throws -> Data
}

/// A Linux or Windows guest's backend, a process in its desktop session spoken to in JSON lines
/// (designs/hobo-ui-linux-windows.md): `hobo-ui-linux.py` over AT-SPI, uinput and hobo's GNOME
/// Shell extension, or `hobo-ui-windows.exe` over UI Automation and SendInput. Each request is
/// `{"op": …, …}`; each answer `{"ok": …}` or `{"error": "…"}`. Elements are numbers the backend
/// gives out, the same number for the same element all session; frames are `[x, y, w, h]` in
/// screen coordinates, which `scale` turns into screenshot pixels.
public final class RemoteBackend: UIBackend {
    public typealias Element = RemoteElement

    let transport: UITransport
    public let platform: UIPlatform
    public let scale: PixelScale
    public let screen: CGRect
    let access: String?

    /// Says hello, learning the guest's platform, scale and screen.
    public init(transport: UITransport) throws {
        self.transport = transport
        let hello = try Self.call(transport, "hello") as? [String: Any] ?? [:]
        guard let name = hello["platform"] as? String, let platform = UIPlatform(rawValue: name) else {
            throw UIError.failed("the guest's hobo ui backend didn't say which platform it drives")
        }
        self.platform = platform
        scale = PixelScale(hello["scale"] as? Double ?? 1)
        screen = Self.rect(hello["screen"]) ?? .infinite
        access = hello["access"] as? String
    }

    // MARK: Wire

    /// Sends one request and gives its answer's `ok`, throwing its `error`.
    static func call(_ transport: UITransport, _ op: String, _ arguments: [String: Any] = [:]) throws -> Any? {
        var request = arguments
        request["op"] = op
        let line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let answer = try transport.send(line)
        guard let object = try? JSONSerialization.jsonObject(with: answer, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw UIError.failed("the guest's hobo ui backend answered \(op) with \(String(decoding: answer.prefix(200), as: UTF8.self))")
        }
        if let error = object["error"] as? String { throw UIError.failed(error) }
        let ok = object["ok"]
        return ok is NSNull ? nil : ok
    }

    func call(_ op: String, _ arguments: [String: Any] = [:]) throws -> Any? {
        try Self.call(transport, op, arguments)
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let numbers = value as? [Double], numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    static func wire(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

    /// An element from its JSON: its attributes, and its children when the backend sent them.
    func element(_ value: Any?) -> RemoteElement? {
        guard let node = value as? [String: Any], let id = node["id"] as? Int else { return nil }
        let children = (node["children"] as? [Any]).map { $0.compactMap(element) }
        return RemoteElement(backend: self, id: id, attributes: attributes(node), children: children)
    }

    func attributes(_ node: [String: Any]) -> ElementAttributes {
        ElementAttributes(
            platform: platform, role: node["role"] as? String ?? "unknown", subrole: node["subrole"] as? String,
            title: node["title"] as? String, identifier: node["identifier"] as? String, label: node["label"] as? String,
            value: node["value"] as? String, frame: Self.rect(node["frame"]), enabled: node["enabled"] as? Bool ?? true,
            focused: node["focused"] as? Bool ?? false, selected: node["selected"] as? Bool ?? false, checked: node["checked"] as? Bool
        )
    }

    func elements(_ value: Any?) -> [RemoteElement] { (value as? [Any])?.compactMap(element) ?? [] }

    static func identity(_ value: Any?) -> AppIdentity? {
        // Not trapping on a pid out of Int32's range: the guest's number, in the VM process.
        guard let app = value as? [String: Any], let number = app["pid"] as? Int, let pid = Int32(exactly: number) else { return nil }
        return AppIdentity(name: app["name"] as? String ?? "pid \(pid)", id: app["id"] as? String, pid: pid)
    }

    static func running(_ value: Any?) -> RunningApp? {
        guard let identity = identity(value) else { return nil }
        return RunningApp(identity: identity, aliases: (value as? [String: Any])?["aliases"] as? [String] ?? [])
    }

    func point(_ point: CGPoint) -> [String: Any] { ["x": point.x, "y": point.y] }

    // MARK: UIBackend

    public func checkAccess() throws {
        if let access { throw UIError.noAccess(access) }
    }

    public func apps() throws -> [RunningApp] {
        let answer = try call("apps") as? [String: Any]
        return (answer?["apps"] as? [Any])?.compactMap(Self.running) ?? []
    }

    public func frontmostApp() throws -> RunningApp? {
        let answer = try call("apps") as? [String: Any]
        guard let focused = (answer?["focused"] as? Int).flatMap(Int32.init(exactly:)) else { return nil }
        return (answer?["apps"] as? [Any])?.compactMap(Self.running).first { $0.identity.pid == focused }
    }

    public func root(of app: RunningApp) throws -> RemoteElement {
        guard let root = element(try call("tree", ["pid": Int(app.identity.pid)])) else {
            throw UIError.failed("\(app.identity.name) has no accessibility tree")
        }
        return root
    }

    public func app(of element: RemoteElement) -> AppIdentity {
        (try? Self.identity(call("app_of", ["id": element.id]))) ?? AppIdentity(name: "an app", id: nil, pid: 0)
    }

    public func current(_ element: RemoteElement) -> ElementAttributes? {
        (try? call("node", ["id": element.id]) as? [String: Any]).map(attributes)
    }

    public func parent(of element: RemoteElement) -> RemoteElement? {
        try? self.element(call("parent", ["id": element.id]))
    }

    public func same(_ a: RemoteElement, _ b: RemoteElement) -> Bool { a.id == b.id }

    public func element(at point: CGPoint) -> RemoteElement? {
        try? element(call("at", self.point(point)))
    }

    public func bringForward(_ element: RemoteElement, of app: RunningApp) {
        _ = try? call("raise", ["id": element.id, "pid": Int(app.identity.pid)])
    }

    public func windows(over area: CGRect) -> [WindowState] {
        let windows = (try? call("windows", ["area": Self.wire(area)])) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard let id = window["id"] as? Int, let bounds = Self.rect(window["bounds"]) else { return nil }
            return WindowState(id: id, bounds: bounds, alpha: window["alpha"] as? Double ?? 1)
        }
    }

    public func openMenu(notAt point: CGPoint) -> String? {
        (try? call("open_menu", self.point(point))) as? String
    }

    public func press(_ element: RemoteElement) throws {
        _ = try call("press", ["id": element.id])
    }

    public func scrollToVisible(_ element: RemoteElement) -> Bool {
        ((try? call("scroll_to", ["id": element.id])) as? Bool) ?? false
    }

    public func menuBar(of root: RemoteElement) -> RemoteElement? {
        try? element(call("menubar", ["id": root.id]))
    }

    public func menuItems(of element: RemoteElement) -> [RemoteElement] {
        (try? elements(call("menu_items", ["id": element.id]))) ?? []
    }

    public func menuItem(_ element: RemoteElement) -> MenuItemInfo {
        let info = (try? call("menu_item", ["id": element.id])) as? [String: Any] ?? [:]
        return MenuItemInfo(
            title: info["title"] as? String ?? element.attributes().title ?? "", enabled: info["enabled"] as? Bool ?? true,
            checked: info["checked"] as? Bool ?? false, shortcut: info["shortcut"] as? String, submenu: info["submenu"] as? Bool ?? false
        )
    }

    func modifiers(_ modifiers: [Modifier]) -> [String] { modifiers.map(\.rawValue) }

    public func click(at point: CGPoint, right: Bool, count: Int, modifiers: [Modifier]) {
        var arguments = self.point(point)
        arguments["right"] = right
        arguments["count"] = count
        arguments["mods"] = self.modifiers(modifiers)
        _ = try? call("click", arguments)
    }

    public func drag(from start: CGPoint, to end: CGPoint, modifiers: [Modifier]) {
        _ = try? call("drag", ["from": [start.x, start.y], "to": [end.x, end.y], "mods": self.modifiers(modifiers)])
    }

    public func scroll(at point: CGPoint, _ direction: HoboUI.ScrollDirection, lines: Int) {
        var arguments = self.point(point)
        arguments["direction"] = direction.rawValue
        arguments["lines"] = lines
        _ = try? call("scroll", arguments)
    }

    public func scroll(at point: CGPoint, _ direction: HoboUI.ScrollDirection, distance: Double) {
        var arguments = self.point(point)
        arguments["direction"] = direction.rawValue
        arguments["distance"] = distance
        _ = try? call("scroll", arguments)
    }

    public func key(_ spec: KeySpec) {
        _ = try? call("key", ["key": spec.key, "mods": modifiers(spec.modifiers)])
    }

    public func type(_ text: String) {
        _ = try? call("type", ["text": text])
    }

    public func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

/// An element of a Linux or Windows guest's app, as its backend sent it. Its attributes are as
/// they were then; `RemoteBackend.current` asks again. Children come with a tree, or are asked
/// for the first time they're wanted.
public final class RemoteElement: AccessibleElement {
    let backend: RemoteBackend
    public let id: Int
    let fetched: ElementAttributes
    private var cached: [RemoteElement]?

    init(backend: RemoteBackend, id: Int, attributes: ElementAttributes, children: [RemoteElement]?) {
        self.backend = backend
        self.id = id
        fetched = attributes
        cached = children
    }

    public func attributes() -> ElementAttributes { fetched }

    public func children() -> [RemoteElement] {
        if let cached { return cached }
        let fetched = (try? backend.elements(backend.call("children", ["id": id]))) ?? []
        cached = fetched
        return fetched
    }
}
