/// Where an element is, as a path from its app: at each level, its role, its name (`ElementAttributes.name`)
/// and which of the siblings sharing both it is. A named element keeps its locator when siblings
/// come and go around it; an unnamed one is known only by position among its unnamed peers.
public struct Locator: Hashable, Codable, Sendable, CustomStringConvertible {
    public struct Step: Hashable, Codable, Sendable {
        public var role: String
        public var name: String?
        public var index: Int
        /// Whether it was its parent's only child of its role, when the step was taken: such an
        /// ancestor is followed through a rename (`loose`). Not part of the step's identity.
        public var soleOfRole: Bool

        public init(role: String, name: String?, index: Int, soleOfRole: Bool = false) {
            self.role = role
            self.name = name
            self.index = index
            self.soleOfRole = soleOfRole
        }

        public static func == (a: Step, b: Step) -> Bool { a.role == b.role && a.name == b.name && a.index == b.index }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(role)
            hasher.combine(name)
            hasher.combine(index)
        }

        func matches(_ attributes: ElementAttributes) -> Bool {
            attributes.role == role && attributes.name == name
        }
    }

    public var steps: [Step]

    public init(_ steps: [Step] = []) { self.steps = steps }

    public func appending(_ step: Step) -> Locator { Locator(steps + [step]) }

    /// The locator with the names of its ancestors that were the only children of their role left
    /// out, which a rename of one of them doesn't change; nil when no step is loosened. `RefMap`
    /// keeps a ref through such a rename by it, as `resolve` follows one.
    public var loose: Locator? {
        guard steps.dropLast().contains(where: { $0.soleOfRole && $0.name != nil }) else { return nil }
        var steps = steps
        for i in steps.indices.dropLast() where steps[i].soleOfRole { steps[i].name = nil }
        return Locator(steps)
    }

    public var description: String {
        steps.map { step in "\(step.role)\(step.name.map { ":\($0)" } ?? "")[\(step.index)]" }.joined(separator: "/")
    }

    /// The steps for `children`, in order: each child's role, name and index among the earlier
    /// children that share both.
    public static func steps(for children: [ElementAttributes]) -> [Step] {
        var seen: [Step: Int] = [:]
        var roles: [String: Int] = [:]
        for child in children { roles[child.role, default: 0] += 1 }
        return children.map { child in
            let key = Step(role: child.role, name: child.name, index: 0)
            let index = seen[key, default: 0]
            seen[key] = index + 1
            return Step(role: child.role, name: child.name, index: index, soleOfRole: roles[child.role] == 1)
        }
    }

    /// Walks the path again from `root`. Nil when any step no longer finds its element: the
    /// element is gone, renamed, or has fewer like-named siblings than it had. An ancestor that was
    /// renamed is still followed when it's the only child of its role there, since apps name
    /// windows and tabs after the document in them (GNOME Text Editor after its first line, as
    /// it's typed): the element itself must still match exactly.
    public func resolve<E: AccessibleElement>(from root: E) -> E? {
        var current = root
        for (depth, step) in steps.enumerated() {
            let children = current.children()
            let found = zip(children, Self.steps(for: children.map { $0.attributes() })).first { $0.1 == step }?.0
            if let found {
                current = found
                continue
            }
            let sameRole = children.filter { $0.attributes().role == step.role }
            guard depth < steps.count - 1, step.index == 0, sameRole.count == 1 else { return nil }
            current = sameRole[0]
        }
        return current
    }
}
