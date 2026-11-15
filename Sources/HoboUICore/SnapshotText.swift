import Foundation

/// An app as `snapshot` reports it.
public struct AppSnapshot: Codable, Equatable, Sendable {
    public var app: AppIdentity
    /// Screenshot pixels per point: 1 headless, 2 while a Retina window shows the guest.
    public var scale: Double
    public var elements: [SnapshotNode]

    public init(app: AppIdentity, scale: Double, elements: [SnapshotNode]) {
        self.app = app
        self.scale = scale
        self.elements = elements
    }

    /// The compact tree, one element a line, in the manner of Playwright's aria snapshots:
    ///
    ///     app TextEdit (com.apple.TextEdit) pid 512
    ///     - window "Untitled" [e1] (0,25 800×600)
    ///       - button "Save" [e12] #saveButton (840,412 80×28) disabled
    public var text: String {
        var lines = [app.header]
        if scale != 1 { lines.append("scale " + (scale == scale.rounded() ? String(Int(scale)) : String(scale))) }
        for element in elements { Self.render(element, indent: 0, into: &lines) }
        if elements.isEmpty { lines.append("(no windows)") }
        return lines.joined(separator: "\n")
    }

    static func render(_ node: SnapshotNode, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        lines.append(pad + "- " + line(node))
        for child in node.children { render(child, indent: indent + 1, into: &lines) }
        let inner = pad + "  "
        if let count = node.offscreen { lines.append(inner + "… \(count) more offscreen") }
        if let count = node.more { lines.append(inner + "… \(count) more") }
        if let count = node.deeper { lines.append(inner + "… \(count) deeper") }
    }

    /// `button "Save" [e12] #saveButton = "value" (840,412 80×28) disabled focused`
    public static func line(_ node: SnapshotNode) -> String {
        var parts = [node.role]
        if let name = node.name { parts.append(quoted(name)) }
        // An element with no locator (`path(to:)`) has no ref to show.
        if !node.ref.isEmpty { parts.append("[\(node.ref)]") }
        if let identifier = node.identifier { parts.append("#" + identifier) }
        if let value = node.value { parts.append("= " + quoted(value)) }
        if let frame = node.frame { parts.append("(\(frame.x),\(frame.y) \(frame.width)×\(frame.height))") }
        if node.disabled == true { parts.append("disabled") }
        if node.focused == true { parts.append("focused") }
        if node.selected == true { parts.append("selected") }
        if let checked = node.checked { parts.append(checked ? "checked" : "unchecked") }
        return parts.joined(separator: " ")
    }

    /// In quotes, on one line, and cut short past `limit` characters.
    public static func quoted(_ text: String, limit: Int = 80) -> String {
        var text = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return "\"" + text + "\""
    }
}

/// Which app a command acted on.
public struct AppIdentity: Codable, Equatable, Sendable {
    public var name: String
    /// What names the app across launches: a macOS bundle ID, a Linux desktop app ID
    /// (`org.gnome.TextEditor`), a Windows AUMID or exe name.
    public var id: String?
    public var pid: Int32

    public init(name: String, id: String?, pid: Int32) {
        self.name = name
        self.id = id
        self.pid = pid
    }

    public var header: String {
        "app \(name)\(id.map { " (\($0))" } ?? "") pid \(pid)"
    }

    /// Whose `RefMap` file: by ID, so refs outlive a relaunch.
    public var storeKey: String { id ?? "pid-\(pid)" }
}
