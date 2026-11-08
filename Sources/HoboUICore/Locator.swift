/// Where an element is, as a path from its app: at each level, its role, its name (`ElementAttributes.name`)
/// and which of the siblings sharing both it is. A named element keeps its locator when siblings
/// come and go around it; an unnamed one is known only by position among its unnamed peers.
public struct Locator: Hashable, Codable, Sendable, CustomStringConvertible {
    public struct Step: Hashable, Codable, Sendable {
        public var role: String
        public var name: String?
        public var index: Int

        public init(role: String, name: String?, index: Int) {
            self.role = role
            self.name = name
            self.index = index
        }

        func matches(_ attributes: ElementAttributes) -> Bool {
            attributes.role == role && attributes.name == name
        }
    }

    public var steps: [Step]

    public init(_ steps: [Step] = []) { self.steps = steps }

    public func appending(_ step: Step) -> Locator { Locator(steps + [step]) }

    public var description: String {
        steps.map { step in "\(step.role)\(step.name.map { ":\($0)" } ?? "")[\(step.index)]" }.joined(separator: "/")
    }

    /// The steps for `children`, in order: each child's role, name and index among the earlier
    /// children that share both.
    public static func steps(for children: [ElementAttributes]) -> [Step] {
        var seen: [Step: Int] = [:]
        return children.map { child in
            let key = Step(role: child.role, name: child.name, index: 0)
            let index = seen[key, default: 0]
            seen[key] = index + 1
            return Step(role: child.role, name: child.name, index: index)
        }
    }

    /// Walks the path again from `root`. Nil when any step no longer finds its element: the
    /// element is gone, renamed, or has fewer like-named siblings than it had.
    public func resolve<E: AccessibleElement>(from root: E) -> E? {
        var current = root
        for step in steps {
            let children = current.children()
            let attributes = children.map { $0.attributes() }
            var found: E?
            for (child, childStep) in zip(children, Self.steps(for: attributes)) where childStep == step {
                found = child
                break
            }
            guard let found else { return nil }
            current = found
        }
        return current
    }
}
