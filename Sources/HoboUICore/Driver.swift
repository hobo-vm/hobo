import CoreGraphics
import Foundation

/// Runs one `hobo ui` command against a guest's apps, through its platform's `UIBackend`: in a
/// macOS guest from `hobo-ui`, for Linux and Windows guests from the VM process.
public struct UIDriver<Backend: UIBackend> {
    public typealias Element = Backend.Element

    public var backend: Backend
    public var store: RefStore

    public init(backend: Backend, store: RefStore) {
        self.backend = backend
        self.store = store
    }

    var scale: PixelScale { backend.scale }

    public func run(_ command: any ParsableCommand) throws -> Outcome {
        try backend.checkAccess()
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
        var running: RunningApp
        var root: Element
        var identity: AppIdentity { running.identity }
    }

    func app(_ spec: String?) throws -> App {
        let running = try RunningApp.find(spec, in: backend.apps(), frontmost: backend.frontmostApp())
        return App(running: running, root: try backend.root(of: running))
    }

    /// Where a snapshot found the element `ref` names; throws for a ref no snapshot gave.
    func locator(_ ref: Int, in app: App) throws -> Locator {
        guard let locator = store.load(app.identity.storeKey).locator(for: ref) else {
            throw UIError.failed("\(app.identity.name) has no ref \(RefMap.format(ref)); take a snapshot first")
        }
        return locator
    }

    func element(_ ref: Int, in app: App) throws -> Element {
        guard let element = try locator(ref, in: app).resolve(from: app.root) else {
            throw UIError.failed("stale ref \(RefMap.format(ref)): it isn't where it was; take a new snapshot")
        }
        return element
    }

    /// The ref of the one element showing `text` (`click --text`), inside the element `scope` names
    /// if given (`--in`), failing with the candidates when there are several: picking one would be
    /// a guess.
    func ref(showing text: String, partial: Bool, role: String?, in scope: Int?, app spec: String?) throws -> Int {
        let app = try app(spec)
        let container = try scope.map { try element($0, in: app) }
        let matches = elements(showing: text, partial: partial, role: role, under: app.root) { match in
            container.map { isWithin(match, $0) } ?? true
        }
        let nodes = try store.update(app.identity.storeKey) { refs in
            matches.map { SnapshotNode(ref: refs.ref(for: $0.2), attributes: $0.1, scale: scale) }
        }
        // "checkbox elements": a role with an s on the end isn't always its plural.
        let kind = role.map { "\($0.lowercased()) element" } ?? "element"
        let place = scope.map { "\(RefMap.format($0)) in \(app.identity.name)" } ?? app.identity.name
        guard let first = nodes.first, let ref = RefMap.parse(first.ref) else {
            let how = partial ? "shows" : "shows exactly"
            let hint = partial ? "" : ", or --contains to match part of its text"
            if scope == nil, menuBarShows(text, partial: partial, under: app.root) {
                throw UIError.failed(
                    "no \(kind) in \(app.identity.name)'s windows \(how) \(AppSnapshot.quoted(text)), but its menu bar does, which click --text and snapshot leave out: menu \"File\" lists a menu's items and menu \"File > Save\" chooses one"
                )
            }
            // A role nothing there has is likelier a wrong guess at its name than a missing element.
            // Walked down from the scope: asking each element of the app for its parents is a call to the guest apiece.
            let searched = try (scope.map { allElements(under: try element($0, in: app), locator: try locator($0, in: app)) }
                ?? searchableElements(under: app.root)).map(\.1)
            if let role, !searched.contains(where: { $0.hasShownRole(role) }) {
                throw UIError.failed("no \(kind) in \(place)\(rolesHint(searched))")
            }
            throw UIError.failed("no \(kind) in \(place) \(how) \(AppSnapshot.quoted(text)); take a snapshot to see what's there\(hint)")
        }
        guard nodes.count == 1 else {
            let listed = 10
            let lines = nodes.prefix(listed).map { "\n  " + AppSnapshot.line($0) }.joined()
            let rest = nodes.count > listed ? "\n  … \(nodes.count - listed) more" : ""
            let narrow = [role == nil ? "--role" : nil, scope == nil ? "--in <ref> (inside that element)" : nil].compactMap { $0 }
            let advice = "click one by its ref, as in click \(first.ref)" + (narrow.isEmpty ? "" : ", or narrow with \(narrow.joined(separator: " or "))")
            throw UIError.failed("\(nodes.count) \(kind)s in \(place) show \(AppSnapshot.quoted(text)); \(advice):\(lines)\(rest)")
        }
        return ref
    }

    /// The element's attributes now, or as they were fetched if it has gone since.
    func attributes(_ element: Element) -> ElementAttributes {
        backend.current(element) ?? element.attributes()
    }

    /// The element as a snapshot line, with its ref.
    func describe(_ element: Element, ref: Int) -> SnapshotNode {
        SnapshotNode(ref: ref, attributes: attributes(element), scale: scale)
    }

    /// This element, then its parent, and so on up to the app; at most 200, so a parent loop in a
    /// misbehaving app's tree ends.
    func lineage(_ element: Element) -> [Element] {
        Array(sequence(first: element, next: backend.parent).prefix(200))
    }

    /// Whether `element` is `other`, or inside it.
    func isWithin(_ element: Element, _ other: Element) -> Bool {
        lineage(element).contains { backend.same($0, other) }
    }

    // MARK: snapshot

    func snapshot(_ c: HoboUI.Snapshot) throws -> Outcome {
        let app = try app(c.target.app)
        if let role = c.role { return try snapshot(of: role, under: c.root.flatMap(RefMap.parse), in: app) }
        let builder = SnapshotBuilder(options: SnapshotOptions(all: c.all, depth: c.depth), scale: scale)
        let elements = try store.update(app.identity.storeKey) { refs in
            guard let root = c.root.flatMap(RefMap.parse) else {
                return builder.build(root: app.root, locator: Locator(), isApp: true, refs: &refs)
            }
            let element = try element(root, in: app)
            return builder.build(root: element, locator: try locator(root, in: app), isApp: false, refs: &refs)
        }
        let snapshot = AppSnapshot(app: app.identity, scale: scale.factor, elements: elements)
        return Outcome(text: snapshot.text, snapshot: snapshot)
    }

    /// `snapshot --role`: every element of the role in the app, or inside the element `scope`
    /// names, as a list. They're found where `click --text --role` looks, so offscreen ones are in it.
    func snapshot(of role: String, under scope: Int?, in app: App) throws -> Outcome {
        let within = try scope.map { (try element($0, in: app), try locator($0, in: app)) }
        let inside = within.map { allElements(under: $0.0, locator: $0.1) } ?? searchableElements(under: app.root)
        let matches = inside.filter { $0.1.hasShownRole(role) }
        guard !matches.isEmpty else {
            let place = scope.map { "\(RefMap.format($0)) in \(app.identity.name)" } ?? app.identity.name
            throw UIError.failed("no \(role.lowercased()) element in \(place)\(rolesHint(inside.map(\.1)))")
        }
        let nodes = try store.update(app.identity.storeKey) { refs in
            matches.map { SnapshotNode(ref: refs.ref(for: $0.2), attributes: $0.1, scale: scale) }
        }
        let snapshot = AppSnapshot(app: app.identity, scale: scale.factor, elements: nodes)
        return Outcome(text: snapshot.text, snapshot: snapshot)
    }

    /// The roles `elements` have, for the failure of a `--role` that matched none of them: a
    /// guessed role name (`textfield` for `textbox`) is told what there is to choose from.
    func rolesHint(_ elements: [ElementAttributes]) -> String {
        let roles = Set(elements.map(SnapshotNode.shownRole)).sorted()
        return roles.isEmpty ? "" : "; the roles there are \(roles.joined(separator: ", "))"
    }

    func snapshotNow(_ app: App) -> AppSnapshot? {
        let builder = SnapshotBuilder(options: SnapshotOptions(), scale: scale)
        guard let elements = try? store.update(app.identity.storeKey, { refs in
            builder.build(root: app.root, locator: Locator(), isApp: true, refs: &refs)
        }) else { return nil }
        return AppSnapshot(app: app.identity, scale: scale.factor, elements: elements)
    }

    /// What's at a point: the element there and the way to it from its window, in whichever app
    /// it is, and a menu open elsewhere, which a click at the point would go to closing.
    func at(_ c: HoboUI.At) throws -> Outcome {
        // Validation leaves a point.
        guard case .point(let pixels) = try UITarget(parsing: c.point) else { throw UIError.failed("give a point such as 840,412") }
        let point = scale.points(pixels)
        guard let hit = backend.element(at: point) else { throw UIError.failed("nothing answers at \(pixels.x),\(pixels.y)") }
        let identity = backend.app(of: hit)
        let lineage = lineage(hit)
        let elements = try store.update(identity.storeKey) { refs in
            path(to: lineage, same: backend.same, scale: scale, refs: &refs)
        }
        let snapshot = AppSnapshot(app: identity, scale: scale.factor, elements: elements)
        let menu = backend.openMenu(notAt: point)
        let warning = menu.map { "\n\($0) is open elsewhere: a click at \(pixels.x),\(pixels.y) would likely just close it" } ?? ""
        return Outcome(text: snapshot.text + warning, snapshot: snapshot, openMenu: menu)
    }

    // MARK: Pointing

    /// The screen point to act on, having brought a ref's app forward and checked that the
    /// element is what's there.
    func aim(_ target: UITarget, app spec: String?) throws -> Aim {
        switch target {
        case .point(let pixels):
            let point = scale.points(pixels)
            settleWindows(over: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
            return Aim(point: point)
        case .ref(let ref):
            let app = try app(spec)
            let element = try element(ref, in: app)
            let node = describe(element, ref: ref)
            backend.bringForward(element, of: app.running)
            return Aim(point: try hitPoint(element, node: node), node: node, element: element, ref: ref)
        }
    }

    struct Aim {
        var point: CGPoint
        var node: SnapshotNode?
        var element: Element?
        var ref = 0
    }

    /// What a message says the action went to: the element as it is now, or the point.
    func outcomeTarget(_ aim: Aim) -> (String, SnapshotNode?) {
        guard let element = aim.element, let node = aim.node else { return (pixelText(aim.point), nil) }
        let now = after(element, ref: aim.ref, before: node)
        return (AppSnapshot.line(now), now)
    }

    /// The top-level window an element is in (a sheet's parent window, not the sheet), or the
    /// element itself outside one.
    func window(of element: Element) -> Element {
        lineage(element).last { UIRole.windows.contains(attributes($0).role) } ?? element
    }

    /// The element's centre, if a click there would reach it, once the windows over the element's
    /// window have stopped animating.
    func hitPoint(_ element: Element, node: SnapshotNode) throws -> CGPoint {
        // The whole window, not just the element: a sheet opening or closing covers all of it.
        if let area = attributes(window(of: element)).frame { settleWindows(over: area) }
        guard let frame = attributes(element).frame, !frame.isEmpty else {
            throw UIError.failed("\(AppSnapshot.line(node)) has no frame on screen to click; try --press")
        }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        guard backend.screen.contains(centre) else {
            throw UIError.failed("\(AppSnapshot.line(node)) is off the screen; scroll --to \(node.ref) first")
        }
        // Before hit-testing, which can answer with the element itself where it's scrolled out
        // under a bar laid over its scroll area (safeAreaInset): the click goes to the bar.
        if ScrollVisibility.obstruction(of: centre, areas: scrollAreas(around: element)) != nil {
            throw UIError.failed("\(AppSnapshot.line(node)) is scrolled out of view; scroll --to \(node.ref) first")
        }
        guard let hit = backend.element(at: centre) else {
            throw UIError.failed("nothing answers at \(AppSnapshot.line(node))'s centre")
        }
        // Hit-testing can land on something inside the element (a cell's text), or on a container of
        // it that doesn't hit-test its children; either way the click reaches it.
        if isWithin(hit, element) || isWithin(element, hit) { return centre }
        // Within the element's own window, hit-testing isn't to be trusted: SwiftUI answers with the
        // scroll area under a bar laid over it (safeAreaInset), not the bar's button. Only another
        // window, sheet, popover or menu over it keeps a click from it.
        if let mine = container(of: element), let theirs = container(of: hit), backend.same(mine, theirs) { return centre }
        throw UIError.failed("\(AppSnapshot.line(node)) is covered at its centre by \(covering(hit)); close what's over it")
    }

    /// Waits, for up to 2 s, until the on-screen windows over `area` stop moving and fading.
    /// Accessibility gives a window its final frame, and takes a sheet's elements away, while the
    /// window server is still animating it: a prompt grows and fades in over 400 ms, during which a
    /// click at its button goes to what's behind it, and a closing sheet's window fades over its
    /// parent for 100 ms after its elements have gone.
    func settleWindows(over area: CGRect) {
        // Two reads three frames apart that agree: an animation changes something every frame.
        var last = backend.windows(over: area)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            backend.pause(0.05)
            let now = backend.windows(over: area)
            if now == last { return }
            last = now
        }
    }

    /// The sheet, window, popover or menu an element is part of.
    func container(of element: Element) -> Element? {
        lineage(element).first { UIRole.containers.contains(attributes($0).role) }
    }

    /// What's in the way, by the sheet, window, popover or menu it's part of.
    func covering(_ hit: Element) -> String {
        let owner = backend.app(of: hit).name
        guard let container = container(of: hit) else {
            return "\(SnapshotNode.shownRole(attributes(hit))) of \(owner)"
        }
        let a = attributes(container)
        let name = (a.displayName ?? a.identifier).map { " \"\($0)\"" } ?? ""
        return "\(a.role)\(name) of \(owner)"
    }

    /// The element as it is after an action, or as it was if the action took it away.
    func after(_ element: Element, ref: Int, before: SnapshotNode) -> SnapshotNode {
        backend.pause(0.15)
        guard let attributes = backend.current(element) else { return before }
        // An element on its way out (a button that dismissed its own sheet) can still answer, with
        // no size at the screen's corner: (0,1200 0×0) says nothing about what was clicked.
        let lostItsFrame = attributes.frame?.isEmpty == true && before.frame.map { $0.width > 0 && $0.height > 0 } == true
        return lostItsFrame ? before : SnapshotNode(ref: ref, attributes: attributes, scale: scale)
    }

    // MARK: click, drag, scroll

    func click(_ c: HoboUI.Click) throws -> Outcome {
        let target: UITarget
        if let text = c.text {
            target = .ref(try ref(showing: text, partial: c.contains, role: c.role, in: c.in.flatMap(RefMap.parse), app: c.target.app))
        } else {
            // Validation leaves one of --text and the ref or point.
            target = try UITarget(parsing: c.at ?? "")
        }
        if c.press, case .ref(let ref) = target {
            let app = try app(c.target.app)
            let element = try element(ref, in: app)
            let node = describe(element, ref: ref)
            do {
                try backend.press(element)
            } catch {
                throw UIError.failed("pressing \(AppSnapshot.line(node)) failed: \(error)")
            }
            let now = after(element, ref: ref, before: node)
            return Outcome(text: "pressed \(AppSnapshot.line(now))", element: now)
        }
        let aim = try aim(target, app: c.target.app)
        let modifiers = try c.mods.map(Modifier.parseList) ?? []
        let menu = backend.openMenu(notAt: aim.point)
        backend.click(at: aim.point, right: c.right, count: c.double ? 2 : 1, modifiers: modifiers)
        let (what, node) = outcomeTarget(aim)
        let clicked = "\(c.right ? "right-clicked" : c.double ? "double-clicked" : "clicked") \(what)"
        guard let menu else { return Outcome(text: clicked, element: node) }
        return Outcome(
            text: "\(clicked), but \(menu) was open elsewhere, so the click likely just closed it; check before going on",
            element: node, openMenu: menu
        )
    }

    func drag(_ c: HoboUI.Drag) throws -> Outcome {
        let from = try aim(UITarget(parsing: c.from), app: c.target.app)
        let to = try aim(UITarget(parsing: c.to), app: c.target.app)
        backend.drag(from: from.point, to: to.point, modifiers: try c.mods.map(Modifier.parseList) ?? [])
        let what = from.node.map(AppSnapshot.line) ?? pixelText(from.point)
        let (onto, node) = outcomeTarget(to)
        return Outcome(text: "dragged \(what) to \(onto)", element: node)
    }

    func scroll(_ c: HoboUI.Scroll) throws -> Outcome {
        if let toText = c.to, let ref = RefMap.parse(toText) {
            return try scrollIntoView(ref, app: c.target.app)
        }
        guard let at = c.at, let direction = c.direction else { throw UIError.failed("give where and which way") }
        let point: CGPoint
        var node: SnapshotNode?
        switch try UITarget(parsing: at) {
        case .point(let pixels): point = scale.points(pixels)
        case .ref(let ref):
            let app = try app(c.target.app)
            let element = try element(ref, in: app)
            let described = describe(element, ref: ref)
            node = described
            backend.bringForward(element, of: app.running)
            guard let frame = attributes(element).frame else { throw UIError.failed("\(AppSnapshot.line(described)) has no frame") }
            point = CGPoint(x: frame.midX, y: frame.midY)
        }
        backend.scroll(at: point, direction, lines: c.lines)
        return Outcome(text: "scrolled \(direction.rawValue) \(c.lines) at \(node.map(AppSnapshot.line) ?? pixelText(point))", element: node)
    }

    /// The platform's scroll-to-visible where the element has it, then scrolls on the scroll areas
    /// around it, outermost first, until its centre is in view: the test a click makes (`hitPoint`).
    func scrollIntoView(_ ref: Int, app spec: String?) throws -> Outcome {
        let app = try app(spec)
        let element = try element(ref, in: app)
        var node = describe(element, ref: ref)
        backend.bringForward(element, of: app.running)
        // It can leave the element short of view in an area around the one it scrolled.
        let scrolledItself = backend.scrollToVisible(element)
        if scrolledItself { backend.pause(0.2) }
        if !scrolledItself && scrollAreas(around: element).isEmpty {
            throw UIError.failed("\(AppSnapshot.line(node)) isn't in a scroll area")
        }
        for _ in 0..<60 {
            guard let frame = settledFrame(of: element) else { break }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            guard let obstruction = ScrollVisibility.obstruction(of: centre, areas: scrollAreas(around: element)) else {
                node = describe(element, ref: ref)
                return Outcome(text: "scrolled to \(AppSnapshot.line(node))", element: node)
            }
            // A collapsed area shows nothing to scroll at; scrolling where it sits would scroll the
            // area around it instead.
            if obstruction.visible.isEmpty {
                throw UIError.failed("\(AppSnapshot.line(node)) is in a scroll area that shows nothing, so it can't be scrolled into view")
            }
            // By the distance to the middle of what the area shows.
            let wheel = CGPoint(x: obstruction.visible.midX, y: obstruction.visible.midY)
            let vertical = obstruction.direction == .up || obstruction.direction == .down
            let distance = vertical ? abs(centre.y - wheel.y) : abs(centre.x - wheel.x)
            backend.scroll(at: wheel, obstruction.direction, distance: max(distance, 1))
        }
        throw UIError.failed("couldn't scroll \(AppSnapshot.line(node)) into view")
    }

    /// An element's frame once it stops moving, for up to a second: a scroll view goes on moving
    /// its content after the scroll, and a frame read mid-way says it's in view where it comes to
    /// rest out of it.
    func settledFrame(of element: Element) -> CGRect? {
        var frame = backend.current(element)?.frame
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            backend.pause(0.05)
            let now = backend.current(element)?.frame
            if now == frame { break }
            frame = now
        }
        return frame
    }

    /// The frames of the scroll areas an element is in, outermost first: those inside its window,
    /// sheet, popover or menu, since one around that doesn't clip it (`UIRole.containers`).
    func scrollAreas(around element: Element) -> [CGRect] {
        let selfAndAncestors = lineage(element).map { attributes($0) }
        let insideContainer = selfAndAncestors.prefix { !UIRole.containers.contains($0.role) }
        return insideContainer.dropFirst().compactMap { $0.role == "scrollarea" ? $0.frame : nil }.reversed()
    }

    // MARK: Keyboard

    /// Select All: Cmd-A on macOS, Ctrl-A elsewhere.
    var selectAll: KeySpec {
        KeySpec(modifiers: [backend.platform == .macOS ? .command : .control], key: "a")
    }

    func type(_ c: HoboUI.TypeText) throws -> Outcome {
        var node: SnapshotNode?
        if let into = c.into, let ref = RefMap.parse(into) {
            let aim = try aim(.ref(ref), app: c.target.app)
            backend.click(at: aim.point, right: false, count: 1, modifiers: [])
            backend.pause(0.1)
            node = aim.node
        }
        if c.replace {
            backend.key(selectAll)
            // Typing over the selection replaces it; with nothing to type, delete it.
            if c.text.isEmpty { backend.key(KeySpec(modifiers: [], key: "delete")) }
        }
        backend.type(c.text)
        let count = c.text.count
        let typed = "typed \(count) character\(count == 1 ? "" : "s")\(c.replace ? " over what was there" : "")"
        return Outcome(text: typed + (node.map { " into " + AppSnapshot.line($0) } ?? ""), element: node)
    }

    func key(_ c: HoboUI.Key) throws -> Outcome {
        backend.key(try KeySpec.parse(c.key))
        return Outcome(text: "pressed \(c.key)")
    }

    // MARK: menu

    func menu(_ c: HoboUI.Menu) throws -> Outcome {
        let app = try app(c.target.app)
        guard let bar = backend.menuBar(of: app.root) else {
            if backend.platform == .macOS { throw UIError.failed("\(app.identity.name) has no menu bar") }
            throw UIError.failed(
                "\(app.identity.name) has no menu bar: its menus are behind a button; click --text \"Main Menu\" (or the button snapshot shows), then click --text <item> --role menuitem"
            )
        }
        let titles = c.titles
        var items = backend.menuItems(of: bar)
        var path: [String] = []
        var current: Element?
        for title in titles {
            let infos = items.map(backend.menuItem)
            guard let index = infos.firstIndex(where: { MenuPath.matches($0.title, title) }) else {
                let names = infos.map(\.title).filter { !$0.isEmpty }
                let place = path.isEmpty ? "the menu bar" : path.joined(separator: " > ")
                throw UIError.failed("no \"\(title)\" in \(place); it has: \(names.joined(separator: ", "))")
            }
            path.append(title)
            current = items[index]
            items = infos[index].submenu || path.count == 1 ? backend.menuItems(of: items[index]) : []
        }
        guard let current else { throw UIError.failed("give a menu") }
        let chosen = path.joined(separator: " > ")
        let info = backend.menuItem(current)
        if titles.count == 1 || info.submenu {
            let listed = items.map(backend.menuItem)
            return Outcome(text: ([chosen] + listed.map { "  " + $0.line }).joined(separator: "\n"), items: listed)
        }
        guard info.enabled else { throw UIError.failed("\(chosen) is disabled") }
        do {
            try backend.press(current)
        } catch {
            throw UIError.failed("pressing \(chosen) failed: \(error)")
        }
        let state = info.checked ? " (it was checked)" : ""
        return Outcome(text: "chose \(chosen)\(state)", items: [info])
    }

    // MARK: choose

    /// The first element under `root` that `matches`.
    func descendant(of root: Element, where matches: (ElementAttributes) -> Bool) -> Element? {
        allElements(under: root, locator: Locator()).first { matches($0.1) }?.0
    }

    /// The first element under `root` with one of these identifiers.
    func descendant(of root: Element, identifiedBy identifiers: Set<String>) -> Element? {
        descendant(of: root) { $0.identifier.map(identifiers.contains) == true }
    }

    /// Asks every 50 ms until `body` gives a value, for up to `seconds`.
    func poll<T>(_ seconds: Double, _ body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let value = body() { return value }
            // Not `>=`, which Foundation before 27.2's release lacks for Date (see `VMStore.isBuilder`).
            if !(Date() < deadline) { return nil }
            backend.pause(0.05)
        }
    }

    /// Whether `condition` came true within `seconds`.
    func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        poll(seconds) { condition() ? true : nil } != nil
    }

    func choose(_ c: HoboUI.Choose) throws -> Outcome {
        switch backend.platform {
        case .macOS: try chooseInPanel(c)
        case .linux, .windows: try chooseInDialog(c)
        }
    }

    /// Through the panel's Go to Folder sheet, which takes a whole path (a save panel puts its last
    /// part in the name field), with each step waited for: keys typed while the sheet opens are lost.
    /// The identifiers are AppKit's own for NSOpenPanel and NSSavePanel.
    func chooseInPanel(_ c: HoboUI.Choose) throws -> Outcome {
        let app = try app(c.target.app)
        let panels: Set<String> = ["open-panel", "save-panel"]
        guard let panel = descendant(of: app.root, identifiedBy: panels) else {
            throw UIError.failed("\(app.identity.name) has no open or save panel showing")
        }
        backend.bringForward(panel, of: app.running)
        func goTo() -> Element? { descendant(of: panel, identifiedBy: ["GoToWindow"]) }
        if goTo() == nil { backend.key(try KeySpec.parse("cmd+shift+g")) }
        guard let field = poll(3, { goTo().flatMap { descendant(of: $0, identifiedBy: ["PathTextField"]) } }) else {
            throw UIError.failed("the panel's Go to Folder sheet didn't open")
        }
        guard waitUntil(2, { backend.current(field)?.focused == true }) else {
            throw UIError.failed("the Go to Folder sheet's path field didn't take focus")
        }
        backend.key(selectAll)
        backend.type(c.path)
        guard waitUntil(2, { backend.current(field)?.value == c.path }) else {
            throw UIError.failed("the Go to Folder sheet has \(AppSnapshot.quoted(backend.current(field)?.value ?? "")), not the path typed")
        }
        // The sheet looks the path up as it's typed; Return before it has goes nowhere.
        backend.pause(0.3)
        backend.key(KeySpec(modifiers: [], key: "return"))
        guard waitUntil(3, { goTo() == nil }) else {
            throw UIError.failed("the panel wouldn't go to \(c.path), and its Go to Folder sheet is still open: is the path there in the guest?")
        }
        guard let button = descendant(of: panel, identifiedBy: ["OKButton"]) else { throw UIError.failed("the panel has no Open or Save button") }
        let title = attributes(button).displayName ?? "OK"
        guard waitUntil(2, { backend.current(button)?.enabled == true }) else {
            throw UIError.failed("the panel went to \(c.path), but its \(title) button is disabled: it may not let that be chosen")
        }
        guard let point = try? hitPoint(button, node: describe(button, ref: 0)) else {
            throw UIError.failed("the panel went to \(c.path), but something covers its \(title) button; take a snapshot to see what")
        }
        backend.click(at: point, right: false, count: 1, modifiers: [])
        guard waitUntil(3, { descendant(of: app.root, identifiedBy: panels) == nil }) else {
            throw UIError.failed("clicked \(title) with \(c.path), but the panel is still open; take a snapshot to see why")
        }
        return Outcome(text: "chose \(c.path) with the panel's \(title) button")
    }

    /// A GTK file chooser or a Windows common file dialog: both take a whole path in one field
    /// (GTK's location entry, which Ctrl-L opens; Windows' File name box) and go with Return.
    func chooseInDialog(_ c: HoboUI.Choose) throws -> Outcome {
        let linux = backend.platform == .linux
        guard let found = fileDialog(c.target.app) else {
            throw UIError.failed("\((try? app(c.target.app))?.identity.name ?? "the app") has no file dialog showing")
        }
        let app = try app(c.target.app)
        backend.bringForward(found, of: app.running)
        let field: Element
        var typed = c.path
        if linux, descendant(of: found, identifiedBy: ["filename_widget"]) != nil {
            field = try nautilusFileNameBox(goingTo: c.path, spec: c.target.app)
            typed = (c.path as NSString).lastPathComponent
        } else if linux {
            field = try typeInLocationBar(nil, spec: c.target.app)
        } else {
            guard let box = fileNameBox(in: found) else { throw UIError.failed("the file dialog has no File name box") }
            backend.bringForward(box, of: app.running)
            guard let point = try? hitPoint(box, node: describe(box, ref: 0)) else {
                throw UIError.failed("something covers the file dialog's File name box; take a snapshot to see what")
            }
            backend.click(at: point, right: false, count: 1, modifiers: [])
            field = box
        }
        backend.key(selectAll)
        backend.type(typed)
        guard waitUntil(2, { backend.current(field)?.value == typed }) else {
            throw UIError.failed("the file dialog's field has \(AppSnapshot.quoted(backend.current(field)?.value ?? "")), not the path typed")
        }
        backend.pause(0.3)
        backend.key(KeySpec(modifiers: [], key: "return"))
        guard waitUntil(3, { fileDialog(c.target.app) == nil }) else {
            throw UIError.failed("pressed Return with \(c.path), but the file dialog is still open: is the path there in the guest? Take a snapshot to see why")
        }
        return Outcome(text: "chose \(c.path) in the file dialog")
    }

    /// Nautilus's save chooser, whose location bar only goes to folders and whose File Name box
    /// takes no slashes: goes to `path`'s folder, then opens the File Name box and gives it.
    func nautilusFileNameBox(goingTo path: String, spec: String?) throws -> Element {
        // As strings: a guest path, perhaps from ~, that the host's file system knows nothing of.
        let folder = (path as NSString).deletingLastPathComponent + "/"
        try typeInLocationBar(folder, spec: spec)
        backend.key(KeySpec(modifiers: [], key: "return"))
        guard waitUntil(3, { fileDialog(spec).flatMap(focusedTextbox) == nil }) else {
            throw UIError.failed("the file dialog's location field didn't go to \(folder): is it a folder in the guest?")
        }
        // Looked up afresh each time: the dialog's tree as it first showed may not have it yet.
        func nameButton() -> Element? {
            fileDialog(spec)
                .flatMap { descendant(of: $0, identifiedBy: ["filename_widget"]) }
                .flatMap { descendant(of: $0, where: { $0.role == "button" }) }
        }
        // A click as the location bar closes can go nowhere, so click until the box opens.
        for _ in 0..<3 {
            if let button = nameButton() {
                guard let point = try? hitPoint(button, node: describe(button, ref: 0)) else {
                    throw UIError.failed("something covers the file dialog's File Name button; take a snapshot to see what")
                }
                backend.click(at: point, right: false, count: 1, modifiers: [])
            }
            if let entry = poll(1, { fileDialog(spec).flatMap(focusedTextbox) }) { return entry }
        }
        throw UIError.failed("the file dialog's File Name box didn't open")
    }

    /// Opens a GTK file chooser's location bar with Ctrl-L and gives it, after typing `text` there
    /// when there is some.
    @discardableResult
    func typeInLocationBar(_ text: String?, spec: String?) throws -> Element {
        backend.key(KeySpec(modifiers: [.control], key: "l"))
        guard let entry = poll(3, { fileDialog(spec).flatMap(focusedTextbox) }) else {
            throw UIError.failed("the file dialog's location field didn't open")
        }
        guard let text else { return entry }
        backend.key(selectAll)
        backend.type(text)
        // GTK completes a path inline, selecting what it adds; Delete drops that.
        if waitUntil(1, { (backend.current(entry)?.value).map { $0 != text && $0.hasPrefix(text) } == true }) {
            backend.key(KeySpec(modifiers: [], key: "delete"))
        }
        guard waitUntil(2, { backend.current(entry)?.value == text }) else {
            throw UIError.failed("the file dialog's location field has \(AppSnapshot.quoted(backend.current(entry)?.value ?? "")), not \(AppSnapshot.quoted(text))")
        }
        return entry
    }

    /// The file dialog the app is showing: GTK's `file chooser`, or a Windows window with a File
    /// name box. On Linux a sandboxed or GTK 4 app's chooser comes from the file chooser portal, in
    /// another process (Nautilus on GNOME), so after the app's own tree every app's is searched.
    func fileDialog(_ spec: String?) -> Element? {
        guard let app = try? app(spec) else { return nil }
        if backend.platform == .linux {
            // GTK 3 has a file chooser role; GTK 4 doesn't, and its portal's is Nautilus's window.
            let isChooser: (ElementAttributes) -> Bool = { $0.nativeRole == "file chooser" || $0.identifier == "NautilusFileChooser" }
            if let own = descendant(of: app.root, where: isChooser) { return own }
            let others = ((try? backend.apps()) ?? []).filter { $0.identity.pid != app.running.identity.pid }
            // A loop, not lazy.compactMap, which runs its transform twice, and the tree can change between.
            for other in others {
                if let root = try? backend.root(of: other), let chooser = descendant(of: root, where: isChooser) { return chooser }
            }
            return nil
        }
        return allElements(under: app.root, locator: Locator()).first { element, a, _ in
            ["dialog", "window"].contains(a.role) && fileNameBox(in: element) != nil
        }?.0
    }

    /// A Windows file dialog's File name box: the edit field of its `File name:` combo box.
    func fileNameBox(in dialog: Element) -> Element? {
        descendant(of: dialog) { $0.role == "textbox" && $0.displayName?.hasPrefix("File name") == true }
    }

    /// The focused text field in `root`.
    func focusedTextbox(_ root: Element) -> Element? {
        descendant(of: root) { $0.role == "textbox" && $0.focused }
    }

    // MARK: wait

    func wait(_ c: HoboUI.Wait) throws -> Outcome {
        let deadline = Date().addingTimeInterval(c.timeout)
        let what = c.ref.map { "element \($0)" } ?? c.text.map { "\(c.role?.lowercased() ?? "text") \"\($0)\"" } ?? "app \(c.target.app ?? "")"
        // What kept a --gone wait waiting, for its timeout to name: a view that's hidden can still
        // be an accessibility element, and only its line in the snapshot would otherwise say so.
        var stillThere: SnapshotNode?
        while true {
            // Looked up afresh each time: the app may be starting, quitting or relaunching.
            if let app = try? app(c.target.app) {
                let found = try check(c, in: app)
                stillThere = found.node
                if found.present != c.gone {
                    let text = c.gone ? "\(what) is gone" : found.node.map { "found " + AppSnapshot.line($0) } ?? "\(app.identity.name) is running with a window"
                    return Outcome(text: text, element: c.gone ? nil : found.node)
                }
            } else if c.gone {
                // The app has quit: its elements and text went with it.
                return Outcome(text: "\(what) is gone")
            }
            if !(Date() < deadline) { break }
            backend.pause(0.1)
        }
        let snapshot = (try? app(c.target.app)).flatMap(snapshotNow)
        let held = c.gone ? stillThere.map { "; still there: " + AppSnapshot.line($0) } ?? "" : ""
        throw UIError.timedOut("timed out after \(c.timeout.formatted())s waiting for \(what)\(c.gone ? " to go" : "")\(held)", snapshot)
    }

    struct Found {
        var present: Bool
        var node: SnapshotNode?
    }

    /// Throws for a ref no snapshot gave, which no amount of waiting will bring.
    func check(_ c: HoboUI.Wait, in app: App) throws -> Found {
        if let ref = c.ref.flatMap(RefMap.parse) {
            guard let element = try locator(ref, in: app).resolve(from: app.root) else { return Found(present: false) }
            return Found(present: true, node: describe(element, ref: ref))
        }
        if let text = c.text {
            for (_, attributes, locator) in searchableElements(under: app.root) where attributes.contains(text) && attributes.hasShownRole(c.role) {
                let ref = try store.update(app.identity.storeKey) { $0.ref(for: locator) }
                return Found(present: true, node: SnapshotNode(ref: ref, attributes: attributes, scale: scale))
            }
            return Found(present: false)
        }
        let windows = app.root.children().filter { UIRole.windows.contains($0.attributes().role) }
        return Found(present: !windows.isEmpty)
    }

    func pixelText(_ point: CGPoint) -> String {
        let pixels = scale.pixels(point)
        return "\(pixels.x),\(pixels.y)"
    }
}
