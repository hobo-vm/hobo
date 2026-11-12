import AppKit
import ApplicationServices
import HoboUICore

/// Runs one `hobo ui` command against the guest's apps.
@MainActor
struct Driver {
    var store = RefStore.standard()
    var scale = PixelScale(Driver.displayScale())

    /// Screenshot pixels per point on the main display.
    static func displayScale() -> Double {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    func run(_ command: any ParsableCommand) throws -> Outcome {
        guard AXIsProcessTrusted() else { throw UIError.notTrusted }
        switch command {
        case let c as HoboUI.Snapshot: return try snapshot(c)
        case let c as HoboUI.At: return try at(c)
        case let c as HoboUI.Click: return try click(c)
        case let c as HoboUI.Drag: return try drag(c)
        case let c as HoboUI.Scroll: return try scroll(c)
        case let c as HoboUI.TypeText: return try type(c)
        case let c as HoboUI.Key: return try key(c)
        case let c as HoboUI.Menu: return try menu(c)
        case let c as HoboUI.Choose: return try choose(c)
        case let c as HoboUI.Wait: return try wait(c)
        default: throw UIError.failed("no such command")
        }
    }

    // MARK: Apps and refs

    struct App {
        var running: NSRunningApplication
        var element: AXElement
        var identity: AppIdentity
    }

    func app(_ spec: String?) throws -> App {
        let running = try Self.findApp(spec)
        let identity = AppIdentity(
            name: running.localizedName ?? running.bundleIdentifier ?? "pid \(running.processIdentifier)",
            bundleID: running.bundleIdentifier, pid: running.processIdentifier
        )
        return App(running: running, element: .application(running.processIdentifier), identity: identity)
    }

    static func findApp(_ spec: String?) throws -> NSRunningApplication {
        let apps = NSWorkspace.shared.runningApplications
        guard let spec else {
            guard let front = NSWorkspace.shared.frontmostApplication else { throw UIError.failed("no app is frontmost; give --app") }
            return front
        }
        if spec.hasPrefix("pid:") {
            guard let pid = pid_t(spec.dropFirst(4)), let app = NSRunningApplication(processIdentifier: pid) else {
                throw UIError.noApp(spec)
            }
            return app
        }
        let byBundle = apps.filter { $0.bundleIdentifier?.caseInsensitiveCompare(spec) == .orderedSame }
        let matches = byBundle.isEmpty ? apps.filter { $0.localizedName?.caseInsensitiveCompare(spec) == .orderedSame } : byBundle
        guard let first = matches.first else { throw UIError.noApp(spec) }
        guard matches.count == 1 else {
            let names = matches.map { "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "no bundle ID"), pid \($0.processIdentifier))" }
            throw UIError.failed("\(spec) matches \(matches.count) apps: \(names.joined(separator: "; ")); give --app pid:<n>")
        }
        return first
    }

    /// Where a snapshot found the element `ref` names; throws for a ref no snapshot gave.
    func locator(_ ref: Int, in app: App) throws -> Locator {
        guard let locator = store.load(app.identity.storeKey).locator(for: ref) else {
            throw UIError.failed("\(app.identity.name) has no ref \(RefMap.format(ref)); take a snapshot first")
        }
        return locator
    }

    func element(_ ref: Int, in app: App) throws -> AXElement {
        guard let element = try locator(ref, in: app).resolve(from: app.element) else {
            throw UIError.failed("stale ref \(RefMap.format(ref)): it isn't where it was; take a new snapshot")
        }
        return element
    }

    /// The ref of the one element showing `text` (`click --text`), failing with the candidates
    /// when there are several: picking one would be a guess.
    func ref(showing text: String, role: String?, app spec: String?) throws -> Int {
        let app = try app(spec)
        let matches = elements(showing: text, role: role, under: app.element)
        let nodes = try store.update(app.identity.storeKey) { refs in
            matches.map { SnapshotNode(ref: refs.ref(for: $0.2), attributes: $0.1, scale: scale) }
        }
        // "checkbox elements": a role with an s on the end isn't always its plural.
        let kind = role.map { "\($0.lowercased()) element" } ?? "element"
        guard let first = nodes.first, let ref = RefMap.parse(first.ref) else {
            throw UIError.failed("no \(kind) in \(app.identity.name) shows exactly \(AppSnapshot.quoted(text)); take a snapshot to see what's there")
        }
        guard nodes.count == 1 else {
            let listed = 10
            let lines = nodes.prefix(listed).map { "\n  " + AppSnapshot.line($0) }.joined()
            let rest = nodes.count > listed ? "\n  … \(nodes.count - listed) more" : ""
            throw UIError.failed("\(nodes.count) \(kind)s in \(app.identity.name) show \(AppSnapshot.quoted(text)); click one by its ref\(role == nil ? ", or narrow with --role" : ""):\(lines)\(rest)")
        }
        return ref
    }

    /// The element as a snapshot line, with its ref.
    func describe(_ element: AXElement, ref: Int) -> SnapshotNode {
        SnapshotNode(ref: ref, attributes: element.attributes(), scale: scale)
    }

    // MARK: snapshot

    func snapshot(_ c: HoboUI.Snapshot) throws -> Outcome {
        let app = try app(c.target.app)
        let builder = SnapshotBuilder(options: SnapshotOptions(all: c.all, depth: c.depth), scale: scale)
        let elements = try store.update(app.identity.storeKey) { refs in
            guard let root = c.root.flatMap(RefMap.parse) else {
                return builder.build(root: app.element, locator: Locator(), isApp: true, refs: &refs)
            }
            let element = try element(root, in: app)
            return builder.build(root: element, locator: try locator(root, in: app), isApp: false, refs: &refs)
        }
        let snapshot = AppSnapshot(app: app.identity, scale: scale.factor, elements: elements)
        return Outcome(text: snapshot.text, snapshot: snapshot)
    }

    func snapshotNow(_ app: App) -> AppSnapshot? {
        let builder = SnapshotBuilder(options: SnapshotOptions(), scale: scale)
        guard let elements = try? store.update(app.identity.storeKey, { refs in
            builder.build(root: app.element, locator: Locator(), isApp: true, refs: &refs)
        }) else { return nil }
        return AppSnapshot(app: app.identity, scale: scale.factor, elements: elements)
    }

    /// What's at a point: the element there and the way to it from its window, in whichever app
    /// it is, and a menu open elsewhere, which a click at the point would go to closing.
    func at(_ c: HoboUI.At) throws -> Outcome {
        // Validation leaves a point.
        guard case .point(let pixels) = try UITarget(parsing: c.point) else { throw UIError.failed("give a point such as 840,412") }
        let point = scale.points(pixels)
        guard let hit = AXElement.at(point) else { throw UIError.failed("nothing answers at \(pixels.x),\(pixels.y)") }
        let running = NSRunningApplication(processIdentifier: hit.pid)
        let identity = AppIdentity(
            name: running?.localizedName ?? running?.bundleIdentifier ?? "pid \(hit.pid)", bundleID: running?.bundleIdentifier, pid: hit.pid
        )
        let lineage = Array(hit.lineage)
        let elements = try store.update(identity.storeKey) { refs in
            path(to: lineage, same: { (a: AXElement, b: AXElement) in CFEqual(a.element, b.element) }, scale: scale, refs: &refs)
        }
        let snapshot = AppSnapshot(app: identity, scale: scale.factor, elements: elements)
        let menu = openMenu(notAt: point)
        let warning = menu.map { "\n\($0) is open elsewhere: a click at \(pixels.x),\(pixels.y) would likely just close it" } ?? ""
        return Outcome(text: snapshot.text + warning, snapshot: snapshot, openMenu: menu)
    }

    // MARK: Pointing

    /// The screen point (in points) to act on, having brought a ref's app forward and checked
    /// that the element is what's there.
    func aim(_ target: UITarget, app spec: String?) throws -> Aim {
        switch target {
        case .point(let pixels):
            return Aim(point: scale.points(pixels))
        case .ref(let ref):
            let app = try app(spec)
            let element = try element(ref, in: app)
            let node = describe(element, ref: ref)
            bringForward(app, element)
            return Aim(point: try hitPoint(element, node: node), node: node, element: element, ref: ref)
        }
    }

    struct Aim {
        var point: CGPoint
        var node: SnapshotNode?
        var element: AXElement?
        var ref = 0
    }

    /// What a message says the action went to: the element as it is now, or the point.
    func outcomeTarget(_ aim: Aim) -> (String, SnapshotNode?) {
        guard let element = aim.element, let node = aim.node else { return (pixelText(aim.point), nil) }
        let now = after(element, ref: aim.ref, before: node)
        return (AppSnapshot.line(now), now)
    }

    /// Makes the app frontmost and raises the element's window, through accessibility (an app
    /// activating another from the background is refused), and waits up to 2 s for it to take.
    func bringForward(_ app: App, _ element: AXElement) {
        if let window = element.element("AXWindow") { _ = window.perform("AXRaise") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.identity.pid { return }
        app.element.set("AXFrontmost", kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if (app.element.attribute("AXFrontmost") as Bool?) == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        Input.pause(0.1)
    }

    /// The element's centre, if a click there would reach it.
    func hitPoint(_ element: AXElement, node: SnapshotNode) throws -> CGPoint {
        guard let frame = element.attributes().frame, !frame.isEmpty else {
            throw UIError.failed("\(AppSnapshot.line(node)) has no frame on screen to click; try --press")
        }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        guard CGDisplayBounds(CGMainDisplayID()).contains(centre) else {
            throw UIError.failed("\(AppSnapshot.line(node)) is off the screen; scroll --to \(node.ref) first")
        }
        guard let hit = AXElement.at(centre) else {
            throw UIError.failed("nothing answers at \(AppSnapshot.line(node))'s centre")
        }
        // Hit-testing can land on something inside the element (a cell's text), or on a container of
        // it that doesn't hit-test its children; either way the click reaches it.
        if hit.isWithin(element) || element.isWithin(hit) { return centre }
        if ScrollVisibility.obstruction(of: centre, areas: scrollAreas(around: element)) != nil { throw UIError.failed("\(AppSnapshot.line(node)) is scrolled out of view; scroll --to \(node.ref) first") }
        // Within the element's own window, hit-testing isn't to be trusted: SwiftUI answers with the
        // scroll area under a bar laid over it (safeAreaInset), not the bar's button. Only another
        // window, sheet, popover or menu over it keeps a click from it.
        if let mine = container(of: element), let theirs = container(of: hit), CFEqual(mine.element, theirs.element) { return centre }
        throw UIError.failed("\(AppSnapshot.line(node)) is covered at its centre by \(covering(hit)); close what's over it")
    }

    private static let containerRoles: Set<String> = ["AXSheet", "AXWindow", "AXPopover", "AXMenu", "AXDialog"]

    /// The sheet, window, popover or menu an element is part of.
    func container(of element: AXElement) -> AXElement? {
        element.lineage.first { Self.containerRoles.contains($0.attributes().role) }
    }

    /// What's in the way, by the sheet, window, popover or menu it's part of.
    func covering(_ hit: AXElement) -> String {
        let owner = NSRunningApplication(processIdentifier: hit.pid)?.localizedName ?? "pid \(hit.pid)"
        guard let attributes = container(of: hit)?.attributes() else {
            return "\(SnapshotNode.displayRole(hit.attributes().role)) of \(owner)"
        }
        let name = (attributes.displayName ?? attributes.identifier).map { " \"\($0)\"" } ?? ""
        return "\(SnapshotNode.displayRole(attributes.role))\(name) of \(owner)"
    }

    /// The element as it is after an action, or as it was if the action took it away.
    func after(_ element: AXElement, ref: Int, before: SnapshotNode) -> SnapshotNode {
        Input.pause(0.15)
        let attributes = element.attributes()
        // An element on its way out (a button that dismissed its own sheet) can still answer, with
        // no size at the screen's corner: (0,1200 0×0) says nothing about what was clicked.
        let lostItsFrame = attributes.frame?.isEmpty == true && before.frame.map { $0.width > 0 && $0.height > 0 } == true
        return attributes.role == "AXUnknown" || lostItsFrame ? before : SnapshotNode(ref: ref, attributes: attributes, scale: scale)
    }

    // MARK: click, drag, scroll

    func click(_ c: HoboUI.Click) throws -> Outcome {
        let target: UITarget
        if let text = c.text {
            target = .ref(try ref(showing: text, role: c.role, app: c.target.app))
        } else {
            // Validation leaves one of --text and the ref or point.
            target = try UITarget(parsing: c.at ?? "")
        }
        if c.press, case .ref(let ref) = target {
            let app = try app(c.target.app)
            let element = try element(ref, in: app)
            let node = describe(element, ref: ref)
            let result = element.perform("AXPress")
            guard result == .success else { throw UIError.failed("AXPress on \(AppSnapshot.line(node)) failed (\(result.rawValue))") }
            let now = after(element, ref: ref, before: node)
            return Outcome(text: "pressed \(AppSnapshot.line(now))", element: now)
        }
        let aim = try aim(target, app: c.target.app)
        let modifiers = try c.mods.map(Modifier.parseList) ?? []
        let menu = openMenu(notAt: aim.point)
        Input.click(at: aim.point, right: c.right, count: c.double ? 2 : 1, modifiers: modifiers)
        let (what, node) = outcomeTarget(aim)
        let clicked = "\(c.right ? "right-clicked" : c.double ? "double-clicked" : "clicked") \(what)"
        guard let menu else { return Outcome(text: clicked, element: node) }
        return Outcome(
            text: "\(clicked), but \(menu) was open elsewhere, so the click likely just closed it; check before going on",
            element: node, openMenu: menu
        )
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
            if hit.lineage.contains(where: { $0.attributes().role == "AXMenu" }) { return nil }
        } else if menus.contains(where: { window in
            (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(point) == true
        }) {
            return nil
        }
        return "a menu\((menu[kCGWindowOwnerName as String] as? String).map { " of \($0)" } ?? "")"
    }

    func drag(_ c: HoboUI.Drag) throws -> Outcome {
        let from = try aim(UITarget(parsing: c.from), app: c.target.app)
        let to = try aim(UITarget(parsing: c.to), app: c.target.app)
        Input.drag(from: from.point, to: to.point, modifiers: try c.mods.map(Modifier.parseList) ?? [])
        let what = from.node.map(AppSnapshot.line) ?? pixelText(from.point)
        let (onto, node) = outcomeTarget(to)
        return Outcome(text: "dragged \(what) to \(onto)", element: node)
    }

    func scroll(_ c: HoboUI.Scroll) throws -> Outcome {
        if let toText = c.to, let ref = RefMap.parse(toText) {
            return try scrollIntoView(ref, app: c.target.app)
        }
        guard let at = c.at, let direction = c.direction else { throw UIError.failed("give where and which way") }
        let target = try UITarget(parsing: at)
        let point: CGPoint
        var node: SnapshotNode?
        switch target {
        case .point(let pixels): point = scale.points(pixels)
        case .ref(let ref):
            let app = try app(c.target.app)
            let element = try element(ref, in: app)
            let described = describe(element, ref: ref)
            node = described
            bringForward(app, element)
            guard let frame = element.attributes().frame else { throw UIError.failed("\(AppSnapshot.line(described)) has no frame") }
            point = CGPoint(x: frame.midX, y: frame.midY)
        }
        Input.scroll(at: point, direction, lines: c.lines)
        return Outcome(text: "scrolled \(direction.rawValue) \(c.lines) at \(node.map(AppSnapshot.line) ?? pixelText(point))", element: node)
    }

    /// AXScrollToVisible where the element has it, then wheel events on the scroll areas around
    /// it, outermost first, until its centre is in view: the test a click makes (`hitPoint`).
    func scrollIntoView(_ ref: Int, app spec: String?) throws -> Outcome {
        let app = try app(spec)
        let element = try element(ref, in: app)
        var node = describe(element, ref: ref)
        bringForward(app, element)
        // It can leave the element short of view in an area around the one it scrolled.
        let scrolledItself = element.actions().contains("AXScrollToVisible") && element.perform("AXScrollToVisible") == .success
        if scrolledItself { Input.pause(0.2) }
        if !scrolledItself && scrollAreas(around: element).isEmpty {
            throw UIError.failed("\(AppSnapshot.line(node)) isn't in a scroll area")
        }
        for _ in 0..<60 {
            guard let frame = element.attributes().frame else { break }
            guard let obstruction = ScrollVisibility.obstruction(of: CGPoint(x: frame.midX, y: frame.midY), areas: scrollAreas(around: element)) else {
                node = describe(element, ref: ref)
                return Outcome(text: "scrolled to \(AppSnapshot.line(node))", element: node)
            }
            Input.scroll(at: CGPoint(x: obstruction.visible.midX, y: obstruction.visible.midY), obstruction.direction, lines: 3)
        }
        throw UIError.failed("couldn't scroll \(AppSnapshot.line(node)) into view")
    }

    /// The frames of the scroll areas an element is in, outermost first.
    func scrollAreas(around element: AXElement) -> [CGRect] {
        element.lineage.dropFirst().compactMap {
            let attributes = $0.attributes()
            return attributes.role == "AXScrollArea" ? attributes.frame : nil
        }.reversed()
    }

    // MARK: Keyboard

    func type(_ c: HoboUI.TypeText) throws -> Outcome {
        var node: SnapshotNode?
        if let into = c.into, let ref = RefMap.parse(into) {
            let aim = try aim(.ref(ref), app: c.target.app)
            Input.click(at: aim.point)
            Input.pause(0.1)
            node = aim.node
        }
        if c.replace {
            Input.key(try KeySpec.parse("cmd+a"))
            // Typing over the selection replaces it; with nothing to type, delete it.
            if c.text.isEmpty { Input.key(try KeySpec.parse("delete")) }
        }
        Input.type(c.text)
        let count = c.text.count
        let typed = "typed \(count) character\(count == 1 ? "" : "s")\(c.replace ? " over what was there" : "")"
        return Outcome(text: typed + (node.map { " into " + AppSnapshot.line($0) } ?? ""), element: node)
    }

    func key(_ c: HoboUI.Key) throws -> Outcome {
        Input.key(try KeySpec.parse(c.key))
        return Outcome(text: "pressed \(c.key)")
    }

    // MARK: menu

    func menu(_ c: HoboUI.Menu) throws -> Outcome {
        let app = try app(c.target.app)
        guard let bar = app.element.element("AXMenuBar") else { throw UIError.failed("\(app.identity.name) has no menu bar") }
        let titles = c.titles
        var items = bar.children()
        var path: [String] = []
        var current: AXElement?
        for title in titles {
            guard let found = items.first(where: { MenuPath.matches(($0.attribute("AXTitle") as String?) ?? "", title) }) else {
                let names = items.compactMap { $0.attribute("AXTitle") as String? }.filter { !$0.isEmpty }
                let place = path.isEmpty ? "the menu bar" : path.joined(separator: " > ")
                throw UIError.failed("no \"\(title)\" in \(place); it has: \(names.joined(separator: ", "))")
            }
            path.append(title)
            current = found
            // A menu bar item, or an item with a submenu, holds its menu as its only child.
            items = found.children().first.map { $0.children() } ?? []
        }
        guard let current else { throw UIError.failed("give a menu") }
        let chosen = path.joined(separator: " > ")
        if titles.count == 1 || !current.children().isEmpty {
            let listed = items.map(MenuItemInfo.init)
            return Outcome(text: ([chosen] + listed.map { "  " + $0.line }).joined(separator: "\n"), items: listed)
        }
        let info = MenuItemInfo(current)
        guard info.enabled else { throw UIError.failed("\(chosen) is disabled") }
        let result = current.perform("AXPress")
        guard result == .success else { throw UIError.failed("pressing \(chosen) failed (\(result.rawValue))") }
        let state = info.checked ? " (it was checked)" : ""
        return Outcome(text: "chose \(chosen)\(state)", items: [info])
    }

    // MARK: choose

    /// The first element under `root` with one of these accessibility identifiers.
    func descendant(of root: AXElement, identifiedBy identifiers: Set<String>) -> AXElement? {
        allElements(under: root, locator: Locator()).first { $0.1.identifier.map(identifiers.contains) == true }?.0
    }

    /// Asks every 50 ms until `body` gives a value, for up to `seconds`.
    func poll<T>(_ seconds: Double, _ body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let value = body() { return value }
            if Date() >= deadline { return nil }
            Input.pause(0.05)
        }
    }

    /// Whether `condition` came true within `seconds`.
    func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        poll(seconds) { condition() ? true : nil } != nil
    }

    /// Through the panel's Go to Folder sheet, which takes a whole path (a save panel puts its last
    /// part in the name field), with each step waited for: keys typed while the sheet opens are lost.
    /// The identifiers are AppKit's own for NSOpenPanel and NSSavePanel.
    func choose(_ c: HoboUI.Choose) throws -> Outcome {
        let app = try app(c.target.app)
        let panels: Set<String> = ["open-panel", "save-panel"]
        guard let panel = descendant(of: app.element, identifiedBy: panels) else {
            throw UIError.failed("\(app.identity.name) has no open or save panel showing")
        }
        bringForward(app, panel)
        func goTo() -> AXElement? { descendant(of: panel, identifiedBy: ["GoToWindow"]) }
        if goTo() == nil { Input.key(try KeySpec.parse("cmd+shift+g")) }
        guard let field = poll(3, { goTo().flatMap { descendant(of: $0, identifiedBy: ["PathTextField"]) } }) else {
            throw UIError.failed("the panel's Go to Folder sheet didn't open")
        }
        guard waitUntil(2, { field.attributes().focused }) else {
            throw UIError.failed("the Go to Folder sheet's path field didn't take focus")
        }
        Input.key(try KeySpec.parse("cmd+a"))
        Input.type(c.path)
        guard waitUntil(2, { field.attributes().value == c.path }) else {
            throw UIError.failed("the Go to Folder sheet has \(AppSnapshot.quoted(field.attributes().value ?? "")), not the path typed")
        }
        // The sheet looks the path up as it's typed; Return before it has goes nowhere.
        Input.pause(0.3)
        Input.key(try KeySpec.parse("return"))
        guard waitUntil(3, { goTo() == nil }) else {
            throw UIError.failed("the panel wouldn't go to \(c.path), and its Go to Folder sheet is still open: is the path there in the guest?")
        }
        guard let button = descendant(of: panel, identifiedBy: ["OKButton"]) else { throw UIError.failed("the panel has no Open or Save button") }
        let title = button.attributes().displayName ?? "OK"
        guard waitUntil(2, { button.attributes().enabled }) else {
            throw UIError.failed("the panel went to \(c.path), but its \(title) button is disabled: it may not let that be chosen")
        }
        guard let point = try? hitPoint(button, node: describe(button, ref: 0)) else {
            throw UIError.failed("the panel went to \(c.path), but something covers its \(title) button; take a snapshot to see what")
        }
        Input.click(at: point)
        guard waitUntil(3, { descendant(of: app.element, identifiedBy: panels) == nil }) else {
            throw UIError.failed("clicked \(title) with \(c.path), but the panel is still open; take a snapshot to see why")
        }
        return Outcome(text: "chose \(c.path) with the panel's \(title) button")
    }

    // MARK: wait

    func wait(_ c: HoboUI.Wait) throws -> Outcome {
        let deadline = Date().addingTimeInterval(c.timeout)
        let what = c.ref.map { "element \($0)" } ?? c.text.map { "text \"\($0)\"" } ?? "app \(c.target.app ?? "")"
        while true {
            // Looked up afresh each time: the app may be starting, quitting or relaunching.
            if let app = try? app(c.target.app) {
                let found = try check(c, in: app)
                if found.present != c.gone {
                    let text = c.gone ? "\(what) is gone" : found.node.map { "found " + AppSnapshot.line($0) } ?? "\(app.identity.name) is running with a window"
                    return Outcome(text: text, element: c.gone ? nil : found.node)
                }
            } else if c.gone {
                // The app has quit: its elements and text went with it.
                return Outcome(text: "\(what) is gone")
            }
            if Date() >= deadline { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let snapshot = (try? app(c.target.app)).flatMap(snapshotNow)
        throw UIError.timedOut("timed out after \(c.timeout.formatted())s waiting for \(what)\(c.gone ? " to go" : "")", snapshot)
    }

    struct Found {
        var present: Bool
        var node: SnapshotNode?
    }

    /// Throws for a ref no snapshot gave, which no amount of waiting will bring.
    func check(_ c: HoboUI.Wait, in app: App) throws -> Found {
        if let ref = c.ref.flatMap(RefMap.parse) {
            guard let element = try locator(ref, in: app).resolve(from: app.element) else { return Found(present: false) }
            return Found(present: true, node: describe(element, ref: ref))
        }
        if let text = c.text {
            for (_, attributes, locator) in searchableElements(under: app.element) where attributes.contains(text) {
                let ref = try store.update(app.identity.storeKey) { $0.ref(for: locator) }
                return Found(present: true, node: SnapshotNode(ref: ref, attributes: attributes, scale: scale))
            }
            return Found(present: false)
        }
        let windows: [AXUIElement] = app.element.attribute("AXWindows") ?? []
        return Found(present: !windows.isEmpty)
    }

    func pixelText(_ point: CGPoint) -> String {
        let pixels = scale.pixels(point)
        return "\(pixels.x),\(pixels.y)"
    }
}

/// A menu item as `menu` lists it.
struct MenuItemInfo: Encodable {
    var title: String
    var enabled: Bool
    var checked: Bool
    /// In `key`'s syntax, e.g. cmd+shift+s.
    var shortcut: String?
    var submenu: Bool

    init(_ item: AXElement) {
        title = item.attribute("AXTitle") ?? ""
        enabled = item.attribute("AXEnabled") ?? true
        checked = !((item.attribute("AXMenuItemMarkChar") as String?) ?? "").isEmpty
        submenu = !item.children().isEmpty
        shortcut = nil
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
    }

    var line: String {
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
struct Outcome: Encodable {
    var text: String
    var element: SnapshotNode?
    var items: [MenuItemInfo]?
    var snapshot: AppSnapshot?
    /// A menu open away from where a click went (or `at`'s point), which it would go to closing.
    var openMenu: String?

    init(text: String, element: SnapshotNode? = nil, items: [MenuItemInfo]? = nil, snapshot: AppSnapshot? = nil, openMenu: String? = nil) {
        self.text = text
        self.element = element
        self.items = items
        self.snapshot = snapshot
        self.openMenu = openMenu
    }

    enum CodingKeys: String, CodingKey { case text = "message", element, items, snapshot, openMenu }
}

enum UIError: Error, CustomStringConvertible {
    case notTrusted
    case noApp(String)
    case failed(String)
    case timedOut(String, AppSnapshot?)

    var description: String {
        switch self {
        case .notTrusted: "Accessibility isn't granted; build this VM from a recipe with [gui_testing]"
        case .noApp(let spec): "no running app matches \(spec)"
        case .failed(let message): message
        case .timedOut(let message, _): message
        }
    }
}
