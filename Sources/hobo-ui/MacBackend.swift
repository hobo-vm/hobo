import AppKit
import ApplicationServices
import HoboUICore

/// macOS's accessibility and input for `UIDriver`: AX for the tree and actions, CGEvents posted
/// where the HID system posts a person's (`Input`). Coordinates are points.
struct MacBackend: UIBackend {
    typealias Element = AXElement

    var platform: UIPlatform { .macOS }
    let scale = PixelScale(MacBackend.displayScale())
    var screen: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    /// Screenshot pixels per point on the main display.
    static func displayScale() -> Double {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    func checkAccess() throws {
        guard AXIsProcessTrusted() else { throw UIError.noAccess("Accessibility isn't granted; build this VM from a recipe with [gui_testing]") }
    }

    // MARK: Apps

    static func running(_ app: NSRunningApplication) -> RunningApp {
        RunningApp(identity: AppIdentity(
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            id: app.bundleIdentifier, pid: app.processIdentifier
        ))
    }

    func apps() throws -> [RunningApp] { NSWorkspace.shared.runningApplications.map(Self.running) }

    func frontmostApp() throws -> RunningApp? { NSWorkspace.shared.frontmostApplication.map(Self.running) }

    func root(of app: RunningApp) throws -> AXElement { .application(app.identity.pid) }

    func app(of element: AXElement) -> AppIdentity {
        NSRunningApplication(processIdentifier: element.pid).map(Self.running)?.identity
            ?? AppIdentity(name: "pid \(element.pid)", id: nil, pid: element.pid)
    }

    // MARK: Elements

    func current(_ element: AXElement) -> ElementAttributes? {
        let attributes = element.attributes()
        return attributes.nativeRole == "AXUnknown" ? nil : attributes
    }

    func parent(of element: AXElement) -> AXElement? { element.parent }

    func same(_ a: AXElement, _ b: AXElement) -> Bool { CFEqual(a.element, b.element) }

    func element(at point: CGPoint) -> AXElement? { AXElement.at(point) }

    /// Makes the app frontmost and raises the element's window, through accessibility (an app
    /// activating another from the background is refused), and waits up to 2 s for it to take.
    func bringForward(_ element: AXElement, of app: RunningApp) {
        if let window = element.element("AXWindow") { _ = window.perform("AXRaise") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.identity.pid { return }
        let root = AXElement.application(app.identity.pid)
        root.set("AXFrontmost", kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if (root.attribute("AXFrontmost") as Bool?) == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        Input.pause(0.1)
    }

    func windows(over area: CGRect) -> [WindowState] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.intersects(area)
            else { return nil }
            return WindowState(id: number, bounds: bounds, alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// An open menu (a pop-up, context or toolbar menu), described for a warning, when `point`
    /// isn't in one: a click outside every open menu goes to dismissing them, not to what's under
    /// the point. A click in a submenu is in a menu, though its parent menu is elsewhere.
    func openMenu(notAt point: CGPoint) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // A closing menu stays listed while it fades out, at alpha 0.
        let menus = windows.filter {
            $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)) && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        guard let menu = menus.first else { return nil }
        // A menu window's bounds take in its shadow, so ask what's at the point; only if nothing
        // answers, fall back on the bounds.
        if let hit = AXElement.at(point) {
            if hit.lineage.contains(where: { $0.attributes().role == "menu" }) { return nil }
        } else if menus.contains(where: { window in
            (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(point) == true
        }) {
            return nil
        }
        return "a menu\((menu[kCGWindowOwnerName as String] as? String).map { " of \($0)" } ?? "")"
    }

    // MARK: Actions

    struct ActionFailed: Error, CustomStringConvertible {
        var error: AXError
        var description: String { "AXPress returned \(error.rawValue)" }
    }

    func press(_ element: AXElement) throws {
        let result = element.perform("AXPress")
        guard result == .success else { throw ActionFailed(error: result) }
    }

    func scrollToVisible(_ element: AXElement) -> Bool {
        element.actions().contains("AXScrollToVisible") && element.perform("AXScrollToVisible") == .success
    }

    // MARK: Menus

    func menuBar(of root: AXElement) -> AXElement? { root.element("AXMenuBar") }

    /// A menu bar's items, or what a menu bar item or menu item opens: it holds its menu as its only child.
    func menuItems(of element: AXElement) -> [AXElement] {
        if element.attributes().nativeRole == "AXMenuBar" { return element.children() }
        return element.children().first.map { $0.children() } ?? []
    }

    func menuItem(_ item: AXElement) -> MenuItemInfo {
        var shortcut: String?
        if let char = item.attribute("AXMenuItemCmdChar") as String?, !char.isEmpty {
            // AXMenuItemCmdModifiers: 1 shift, 2 option, 4 control, 8 no command.
            let bits = (item.attribute("AXMenuItemCmdModifiers") as Int?) ?? 0
            var parts: [String] = []
            if bits & 8 == 0 { parts.append("cmd") }
            if bits & 4 != 0 { parts.append("ctrl") }
            if bits & 2 != 0 { parts.append("opt") }
            if bits & 1 != 0 { parts.append("shift") }
            parts.append(char.lowercased())
            shortcut = parts.joined(separator: "+")
        }
        return MenuItemInfo(
            title: item.attribute("AXTitle") ?? "", enabled: item.attribute("AXEnabled") ?? true,
            checked: !((item.attribute("AXMenuItemMarkChar") as String?) ?? "").isEmpty,
            shortcut: shortcut, submenu: !item.children().isEmpty
        )
    }

    // MARK: Input

    func click(at point: CGPoint, right: Bool, count: Int, modifiers: [Modifier]) {
        Input.click(at: point, right: right, count: count, modifiers: modifiers)
    }

    func drag(from start: CGPoint, to end: CGPoint, modifiers: [Modifier]) { Input.drag(from: start, to: end, modifiers: modifiers) }

    func scroll(at point: CGPoint, _ direction: HoboUI.ScrollDirection, lines: Int) { Input.scroll(at: point, direction, lines: lines) }

    func scroll(at point: CGPoint, _ direction: HoboUI.ScrollDirection, distance: Double) {
        Input.scroll(at: point, direction, points: distance)
    }

    func key(_ spec: KeySpec) { Input.key(spec) }

    func type(_ text: String) { Input.type(text) }

    func pause(_ seconds: Double) { Input.pause(seconds) }
}
