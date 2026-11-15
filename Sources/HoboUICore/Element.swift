import CoreGraphics

/// What `hobo-ui` reads of one accessibility element. Frames are in screen points, as the
/// accessibility API gives them; output converts them to screenshot pixels (`PixelScale`).
public struct ElementAttributes: Equatable, Sendable {
    /// The role snapshots show and `--role` matches: an ARIA name (`UIRole`).
    public var role: String
    /// The platform's own role (`AXButton`, `push button`, `Button`), for `--json`.
    public var nativeRole: String
    /// macOS's subrole (`AXCloseButton`), which names an unnamed element better than its role.
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    /// `AXDescription`: the label of an element with no title, such as an icon button.
    public var label: String?
    public var value: String?
    public var frame: CGRect?
    public var enabled: Bool
    public var focused: Bool
    public var selected: Bool
    /// Whether a checkable element is on, as its platform says; nil for one that isn't checkable.
    public var checked: Bool?

    /// `role` is `platform`'s native role, mapped to the shown one by `UIRole`. On macOS a
    /// checkable element's state is its value (`1` when on) unless `checked` gives it.
    public init(
        platform: UIPlatform = .macOS, role native: String, subrole: String? = nil, title: String? = nil,
        identifier: String? = nil, label: String? = nil, value: String? = nil, frame: CGRect? = nil,
        enabled: Bool = true, focused: Bool = false, selected: Bool = false, checked: Bool? = nil
    ) {
        role = UIRole.aria(platform, role: native, subrole: subrole)
        nativeRole = native
        self.subrole = subrole
        self.title = title.nonEmpty
        // AppKit makes up `_NS:31`-style identifiers for views nobody named; they say nothing.
        self.identifier = identifier.nonEmpty.flatMap { $0.hasPrefix("_NS:") ? nil : $0 }
        self.label = label.nonEmpty
        self.value = value.nonEmpty
        self.frame = frame
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        let checkable = UIRole.checkable.contains(role)
        self.checked = checkable ? checked ?? (platform == .macOS ? value == "1" : false) : nil
    }

    /// What names the element in its locator: its identifier, else its title, else its label.
    /// Never its value, which changes as the app runs (a text field's text, a label's count), so
    /// a ref survives that.
    public var name: String? { identifier ?? title ?? label }

    /// What the tree shows in quotes: the title or label, which is what a person reads.
    public var displayName: String? { title ?? label }

    /// A layout container with nothing to say for itself, folded out of a snapshot: its children
    /// stand in its place.
    public var isUnnamedLayout: Bool {
        UIRole.layout.contains(role) && name == nil && value == nil
    }
}

/// An element of a live app (`hobo-ui`'s `AXElement`) or of a test's synthetic tree.
public protocol AccessibleElement {
    func attributes() -> ElementAttributes
    func children() -> [Self]
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
