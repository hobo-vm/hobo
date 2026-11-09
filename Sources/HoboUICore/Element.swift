import CoreGraphics

/// What `hobo-ui` reads of one accessibility element. Frames are in screen points, as the
/// accessibility API gives them; output converts them to screenshot pixels (`PixelScale`).
public struct ElementAttributes: Equatable, Sendable {
    public var role: String
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

    public init(
        role: String, subrole: String? = nil, title: String? = nil, identifier: String? = nil, label: String? = nil,
        value: String? = nil, frame: CGRect? = nil, enabled: Bool = true, focused: Bool = false, selected: Bool = false
    ) {
        self.role = role
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
        Self.layoutRoles.contains(role) && name == nil && value == nil
    }

    static let layoutRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown"]

    /// For a checkbox, radio button or switch, whether it is on.
    public var checked: Bool? {
        guard ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"].contains(role) || subrole == "AXSwitch" else { return nil }
        return value == "1"
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
