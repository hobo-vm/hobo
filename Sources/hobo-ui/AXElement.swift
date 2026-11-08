import ApplicationServices
import HoboUICore

/// A live accessibility element.
struct AXElement: AccessibleElement {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func application(_ pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }
    static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }

    static let attributeNames = [
        "AXRole", "AXSubrole", "AXTitle", "AXIdentifier", "AXDescription", "AXValue",
        "AXPosition", "AXSize", "AXEnabled", "AXFocused", "AXSelected",
    ]

    /// All of them in one round trip to the app.
    func attributes() -> ElementAttributes {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributeNames as CFArray, [], &values) == .success,
              let array = values as? [AnyObject], array.count == Self.attributeNames.count
        else { return ElementAttributes(role: "AXUnknown") }
        let v = array.map(Self.unwrap)
        var frame: CGRect?
        if let position = v[6].flatMap(Self.point), let size = v[7].flatMap(Self.size) {
            frame = CGRect(origin: position, size: size)
        }
        return ElementAttributes(
            role: v[0] as? String ?? "AXUnknown", subrole: v[1] as? String, title: v[2] as? String, identifier: v[3] as? String,
            label: v[4] as? String, value: v[5].flatMap(Self.text), frame: frame,
            enabled: (v[8] as? Bool) ?? true, focused: (v[9] as? Bool) ?? false, selected: (v[10] as? Bool) ?? false
        )
    }

    func children() -> [AXElement] {
        (attribute("AXChildren") as [AXUIElement]?)?.map(AXElement.init) ?? []
    }

    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return Self.unwrap(value) as? T
    }

    func element(_ name: String) -> AXElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return AXElement(value as! AXUIElement)
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    func actions() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    var parent: AXElement? { element("AXParent") }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// The element at a screen point (in points), whichever app it belongs to.
    static func at(_ point: CGPoint) -> AXElement? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide.element, Float(point.x), Float(point.y), &found) == .success, let found else { return nil }
        return AXElement(found)
    }

    /// Whether this is `other`, or inside it.
    func isWithin(_ other: AXElement) -> Bool {
        var current: AXElement? = self
        var steps = 0
        while let element = current, steps < 200 {
            if CFEqual(element.element, other.element) { return true }
            current = element.parent
            steps += 1
        }
        return false
    }

    /// An AXValue that holds an error (an attribute the element lacks, in a batch) is nil.
    private static func unwrap(_ value: AnyObject) -> AnyObject? {
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// A value as text: strings as they are, numbers and booleans as digits; nothing else.
    private static func text(_ value: AnyObject) -> String? {
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as! Bool) ? "1" : "0" }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
