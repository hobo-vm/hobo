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
    /// activating another from the background is refused).
    func bringForward(_ element: AXElement, of app: RunningApp) {
        if let window = element.element("AXWindow") { _ = window.perform("AXRaise") }
        activate(app.identity.pid)
    }

    /// Makes the app frontmost, waiting up to 2 s for it to take.
    private func activate(_ pid: pid_t) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
        let root = AXElement.application(pid)
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
        // A closing menu stays listed while it fades out, at alpha 0.
        let menus = menuWindows().filter { ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
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

    /// The windows of the menus on screen: menu bar menus, their submenus, pop-up and context menus.
    private func menuWindows() -> [[String: Any]] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    }

    /// Waits, for up to a second, until the app has as many menus on screen as `enough` wants.
    private func waitForMenus(of pid: pid_t, _ enough: (Int) -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let count = menuWindows().count { $0[kCGWindowOwnerPID as String] as? pid_t == pid }
            if enough(count) { return }
            Input.pause(0.01)
        }
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
        guard let menu = element.children().first else { return [] }
        bringUpToDate(menuOf: element)
        return menu.children()
    }

    /// Opens the item's menu and closes it again. An app brings a menu's items up to date only as
    /// it opens: until then accessibility reads them as they last were, "Undo" for what will show
    /// as "Undo Typing", and enabled for what will show disabled. The items keep what they're given.
    /// The app comes forward first: in the background it has no key window to ask, and gives the
    /// items of a menu opened then the wrong states, Undo disabled with something to undo.
    private func bringUpToDate(menuOf item: AXElement) {
        activate(item.pid)
        // A submenu opens from its open parent: the menu bar item first, then each item down to this one.
        let path = item.lineage.filter { ["AXMenuBarItem", "AXMenuItem"].contains($0.attributes().nativeRole) }.reversed()
        var opened: AXElement?
        for (depth, item) in path.enumerated() {
            guard item.perform("AXPress") == .success else { break }
            opened = opened ?? item
            // AXPress returns with the menu still to open, which the app does on its next turn of
            // the run loop. A cancel that gets in first ends the menus above it, and the app then
            // opens this one with nothing left to close it: it sits tracking a menu nobody can
            // see, taking every later click and key (in 12 of 20 `menu "Format > Font > Bold"`).
            waitForMenus(of: item.pid) { $0 > depth }
        }
        // Cancelling the menu bar item's menu closes the submenus open from it.
        _ = opened?.children().first?.perform("AXCancel")
        // Closed before anything else is pressed: the next menu's opening, or the item chosen.
        if opened != nil { waitForMenus(of: item.pid) { $0 == 0 } }
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

    /// Runs the main run loop for the time, rather than sleeping the thread: `NSWorkspace` brings
    /// `runningApplications` up to date only there, so a `wait --app` that slept between its looks
    /// never saw an app that launched after it began, and timed out with the app on screen.
    func pause(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        // Returns at once when the run loop has no sources, so what's left of the time is slept.
        RunLoop.current.run(until: end)
        Input.pause(max(0, end.timeIntervalSinceNow))
    }
}
