import CoreGraphics
import Foundation

/// One element as a snapshot shows it, with the ref to act on it by. Frames are screenshot pixels.
public struct SnapshotNode: Codable, Equatable, Sendable {
    public var ref: String
    public var role: String
    public var name: String?
    public var identifier: String?
    public var value: String?
    public var frame: PixelRect?
    public var disabled: Bool?
    public var focused: Bool?
    public var selected: Bool?
    public var checked: Bool?
    public var children: [SnapshotNode]
    /// Children left out for lying wholly outside their scroll area, or having no size (without `--all`).
    public var offscreen: Int?
    /// Children left out past the limit per container (without `--all`).
    public var more: Int?
    /// Children left out by `--depth`.
    public var deeper: Int?

    public init(ref: Int, attributes a: ElementAttributes, scale: PixelScale) {
        self.ref = RefMap.format(ref)
        role = Self.shownRole(a)
        name = a.displayName
        identifier = a.identifier
        value = a.shownValue
        frame = a.frame.map(scale.pixels)
        disabled = a.enabled ? nil : true
        focused = a.focused ? true : nil
        selected = a.selected ? true : nil
        checked = a.checked
        children = []
    }

    /// The role a snapshot shows for an element. An unnamed one is better told by its subrole: a
    /// window's close button, not a button.
    public static func shownRole(_ a: ElementAttributes) -> String {
        displayRole(a.displayName == nil && a.identifier == nil ? a.subrole ?? a.role : a.role)
    }

    /// `AXButton` → `button`.
    public static func displayRole(_ role: String) -> String {
        (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
    }
}

/// A rectangle in screenshot pixels.
public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

/// Points to screenshot pixels and back: a headless guest's display is 1:1, one shown in a
/// Retina window 2:1. Everything `hobo ui` prints or takes is in pixels, so a coordinate read off
/// a `hobo screenshot` is the one to click.
public struct PixelScale: Equatable, Sendable {
    public var factor: Double

    public init(_ factor: Double) { self.factor = factor > 0 ? factor : 1 }

    public func pixels(_ rect: CGRect) -> PixelRect {
        PixelRect(
            x: Int((rect.minX * factor).rounded()), y: Int((rect.minY * factor).rounded()),
            width: Int((rect.width * factor).rounded()), height: Int((rect.height * factor).rounded())
        )
    }

    public func points(_ point: PixelPoint) -> CGPoint {
        CGPoint(x: Double(point.x) / factor, y: Double(point.y) / factor)
    }

    public func pixels(_ point: CGPoint) -> PixelPoint {
        PixelPoint(x: Int((point.x * factor).rounded()), y: Int((point.y * factor).rounded()))
    }
}

public struct PixelPoint: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct SnapshotOptions: Sendable {
    /// No offscreen or per-container limit.
    public var all = false
    /// Levels below the root to show (1: an app's windows only); nil for all.
    public var depth: Int?
    public var maxChildren = 50

    public init(all: Bool = false, depth: Int? = nil) {
        self.all = all
        self.depth = depth
    }
}

/// Walks an app's tree into `SnapshotNode`s, giving each shown element a ref. Unnamed layout
/// groups are folded away, and (without `--all`) elements outside their scroll area and the
/// children of a container past `maxChildren` are only counted, so a large list costs a line.
public struct SnapshotBuilder {
    public var options: SnapshotOptions
    public var scale: PixelScale

    public init(options: SnapshotOptions, scale: PixelScale) {
        self.options = options
        self.scale = scale
    }

    /// The menu bar is `menu`'s; it's left out of an app's snapshot.
    static let skippedAtAppLevel: Set<String> = ["AXMenuBar"]

    /// The tree under `root` (an app, or the element `--root` named, at `locator`). The root
    /// itself isn't shown when it's the app.
    public func build<E: AccessibleElement>(root: E, locator: Locator, isApp: Bool, refs: inout RefMap) -> [SnapshotNode] {
        let attributes = root.attributes()
        if isApp {
            // An app's children are its windows, with no scroll area to be outside of.
            return walkChildren(of: root, attributes: attributes, locator: locator, clip: nil, depth: 0, isApp: true, refs: &refs).nodes
        }
        var node = SnapshotNode(ref: refs.ref(for: locator), attributes: attributes, scale: scale)
        let level = walkChildren(of: root, attributes: attributes, locator: locator, clip: nil, depth: 0, isApp: false, refs: &refs)
        attach(level, to: &node)
        return [node]
    }

    struct Level {
        var nodes: [SnapshotNode] = []
        var offscreen = 0
        var more = 0
        var deeper = 0
    }

    private func walkChildren<E: AccessibleElement>(
        of element: E, attributes: ElementAttributes, locator: Locator, clip: CGRect?, depth: Int, isApp: Bool, refs: inout RefMap
    ) -> Level {
        var clip = clip
        if attributes.role == "AXScrollArea", let frame = attributes.frame {
            clip = clip.map { $0.intersection(frame) } ?? frame
        }
        let children = element.children()
        let childAttributes = children.map { $0.attributes() }
        var level = Level()
        if let limit = options.depth, depth >= limit {
            level.deeper = children.count
            return level
        }
        var shown = 0
        for (index, (child, step)) in zip(children, Locator.steps(for: childAttributes)).enumerated() {
            let a = childAttributes[index]
            if isApp && Self.skippedAtAppLevel.contains(a.role) { continue }
            // Outside its scroll area, or with no size (a scroll bar's hidden arrows): not on screen.
            if !options.all, let frame = a.frame, frame.isEmpty || clip.map({ !frame.intersects($0) }) == true {
                level.offscreen += 1
                continue
            }
            if !options.all && shown >= options.maxChildren {
                level.more += 1
                continue
            }
            shown += 1
            let childLocator = locator.appending(step)
            if a.isUnnamedLayout {
                // Folded: its children take its place, at its depth.
                let inner = walkChildren(of: child, attributes: a, locator: childLocator, clip: clip, depth: depth, isApp: false, refs: &refs)
                level.nodes += inner.nodes
                level.offscreen += inner.offscreen
                level.more += inner.more
                level.deeper += inner.deeper
                continue
            }
            var node = SnapshotNode(ref: refs.ref(for: childLocator), attributes: a, scale: scale)
            let inner = walkChildren(of: child, attributes: a, locator: childLocator, clip: clip, depth: depth + 1, isApp: false, refs: &refs)
            attach(inner, to: &node)
            level.nodes.append(node)
        }
        return level
    }

    private func attach(_ level: Level, to node: inout SnapshotNode) {
        node.children = level.nodes
        node.offscreen = level.offscreen > 0 ? level.offscreen : nil
        node.more = level.more > 0 ? level.more : nil
        node.deeper = level.deeper > 0 ? level.deeper : nil
    }
}

/// The element and locator of everything under `root`, depth first, offscreen included. Stops
/// after `limit` elements.
public func allElements<E: AccessibleElement>(under root: E, locator: Locator, limit: Int = 20_000) -> [(E, ElementAttributes, Locator)] {
    var found: [(E, ElementAttributes, Locator)] = []
    func visit(_ element: E, _ locator: Locator) {
        let children = element.children()
        let attributes = children.map { $0.attributes() }
        for (index, (child, step)) in zip(children, Locator.steps(for: attributes)).enumerated() {
            guard found.count < limit else { return }
            let childLocator = locator.appending(step)
            found.append((child, attributes[index], childLocator))
            visit(child, childLocator)
        }
    }
    visit(root, locator)
    return found
}

/// What `wait --text` and `click --text` look through under an app: everything in it, offscreen
/// included, except what a snapshot leaves out at the app's level (the menu bar, which is `menu`'s).
public func searchableElements<E: AccessibleElement>(under app: E) -> [(E, ElementAttributes, Locator)] {
    allElements(under: app, locator: Locator()).filter { _, _, locator in
        guard let topLevelRole = locator.steps.first?.role else { return true }
        return !SnapshotBuilder.skippedAtAppLevel.contains(topLevelRole)
    }
}

/// The elements under `root` (an app) showing exactly `text`, for `click --text`. `role` keeps
/// only those a snapshot shows with that role. Of an element and one inside it that both match
/// (a cell and its text), only the outer; of matches with the same role in the same frame (a menu
/// item AppKit reports twice), only the first, since a click there reaches either.
public func elements<E: AccessibleElement>(showing text: String, role: String?, under root: E) -> [(E, ElementAttributes, Locator)] {
    var found: [(E, ElementAttributes, Locator)] = []
    for (element, attributes, locator) in searchableElements(under: root) {
        let hasRole = role.map { SnapshotNode.shownRole(attributes).caseInsensitiveCompare($0) == .orderedSame } ?? true
        guard hasRole, attributes.shows(text) else { continue }
        // Depth first, so an element's ancestors come before it.
        let isInsideAMatch = found.contains { locator.steps.starts(with: $0.2.steps) }
        let isAMatchAgain = attributes.frame.map { frame in
            !frame.isEmpty && found.contains { $0.1.role == attributes.role && $0.1.frame == frame }
        } ?? false
        if !isInsideAMatch && !isAMatchAgain { found.append((element, attributes, locator)) }
    }
    return found
}

extension ElementAttributes {
    /// The value as a snapshot shows it: not a checkbox's, which is its state (`checked`).
    public var shownValue: String? { checked == nil ? value : nil }

    /// The text the element shows, which `click --text` and `wait --text` match against: its
    /// title, shown value and label, with `...` as `…` so that either spelling finds the other.
    var shownTexts: [String] {
        [title, shownValue, label].compactMap { $0.map(MenuPath.normalized) }
    }

    /// Whether `text` is the whole of something the element shows.
    public func shows(_ text: String) -> Bool { shownTexts.contains(MenuPath.normalized(text)) }

    /// Whether `text` is part of something the element shows.
    public func contains(_ text: String) -> Bool {
        let wanted = MenuPath.normalized(text)
        return shownTexts.contains { $0.contains(wanted) }
    }
}
