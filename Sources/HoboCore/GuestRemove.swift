import Foundation

/// A `hobo rm`: guest paths to remove, which the VM process has the guest's agent remove as the
/// guest user. It removes files in a VM; `hobo delete` is what removes a VM.
public struct GuestRemove: Codable, Equatable, Sendable {
    /// Guest paths; a relative one is from the guest user's home.
    public var paths: [String]
    /// `--force`: a path that isn't there is no failure.
    public var force: Bool

    public init(paths: [String], force: Bool = false) {
        self.paths = paths
        self.force = force
    }

    /// Parses `<vm>:<path>...`, all in the same VM.
    public static func parse(_ operands: [String], force: Bool = false) throws -> (vm: String, remove: GuestRemove) {
        let guests = try operands.map { operand in
            guard case .guest(let vm, let path) = GuestOperand(operand) else {
                // A bare VM name is someone reaching for `hobo delete`.
                if (try? VMStore.validate(operand)) != nil { throw GuestRemoveError.vmName(operand) }
                throw GuestRemoveError.hostPath(operand)
            }
            if path.isEmpty { throw GuestRemoveError.emptyPath(operand) }
            return (vm: vm, path: path)
        }
        guard let vm = guests.first?.vm else { throw GuestRemoveError.noPaths }
        guard guests.allSatisfy({ $0.vm == vm }) else { throw GuestRemoveError.severalGuests }
        return (vm, GuestRemove(paths: guests.map(\.path), force: force))
    }
}

public enum GuestRemoveError: Error, Equatable, CustomStringConvertible {
    case noPaths
    case vmName(String)
    case hostPath(String)
    case emptyPath(String)
    case severalGuests

    public var description: String {
        switch self {
        case .noPaths: "give the guest paths to remove, as <vm>:<path>"
        case .vmName(let name): "rm removes files in a VM, given as \(name):<path>; to delete the VM \(name) itself, use hobo delete \(name)"
        case .hostPath(let path): "\(path) isn't a guest path: rm removes files in a VM, given as <vm>:<path>"
        case .emptyPath(let operand): "\(operand) names no path in the VM"
        case .severalGuests: "rm paths must all be in the same VM"
        }
    }
}
