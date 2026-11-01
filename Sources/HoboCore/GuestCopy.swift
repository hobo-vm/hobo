import Foundation

/// A `hobo cp` between host paths and one guest, run by the VM process with scp. Host paths are
/// absolute, since the VM process has its own working directory.
public struct GuestCopy: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case toGuest
        case fromGuest
    }

    public var direction: Direction
    /// Host paths when copying to the guest, guest paths when copying from it.
    public var sources: [String]
    /// A guest path when copying to the guest, a host path when copying from it.
    public var destination: String
    public var recursive: Bool

    public init(direction: Direction, sources: [String], destination: String, recursive: Bool) {
        self.direction = direction
        self.sources = sources
        self.destination = destination
        self.recursive = recursive
    }

    /// Parses scp-style operands, `<src>... <dst>`, where exactly one side names a guest as
    /// `<vm>:<path>`. A colon after a slash (`./a:b`) is part of a host path, as with scp.
    public static func parse(_ operands: [String], recursive: Bool, currentDirectory: URL) throws -> (vm: String, copy: GuestCopy) {
        guard operands.count >= 2, let last = operands.last else { throw GuestCopyError.tooFewOperands }
        let sources = operands.dropLast().map(Operand.init)
        let destination = Operand(last)
        func absolute(_ path: String) -> String {
            let absolute = URL(filePath: path, relativeTo: currentDirectory).standardizedFileURL.path
            // A trailing slash tells scp the destination must be a directory; keep it.
            return path.hasSuffix("/") && !absolute.hasSuffix("/") ? absolute + "/" : absolute
        }

        if case .guest(let vm, let path) = destination {
            if sources.contains(where: \.isGuest) { throw GuestCopyError.guestToGuest }
            let hostPaths = sources.map { absolute($0.path) }
            return (vm, GuestCopy(direction: .toGuest, sources: hostPaths, destination: path, recursive: recursive))
        }
        guard case .guest(let vm, _) = sources.first(where: \.isGuest) else { throw GuestCopyError.noGuest }
        var guestPaths: [String] = []
        for source in sources {
            guard case .guest(let name, let path) = source else { throw GuestCopyError.mixedSources }
            guard name == vm else { throw GuestCopyError.severalGuests }
            guestPaths.append(path)
        }
        return (vm, GuestCopy(direction: .fromGuest, sources: guestPaths, destination: absolute(destination.path), recursive: recursive))
    }

    /// scp's arguments (before its connection options) for a guest reached as `remote` (`user@host`).
    public func scpArguments(remote: String) -> [String] {
        let operands = switch direction {
        case .toGuest: sources + ["\(remote):\(destination)"]
        case .fromGuest: sources.map { "\(remote):\($0)" } + [destination]
        }
        return ["-q"] + (recursive ? ["-r"] : []) + ["--"] + operands
    }

    private enum Operand {
        case host(String)
        case guest(vm: String, path: String)

        init(_ operand: String) {
            if let colon = operand.firstIndex(of: ":") {
                let vm = String(operand[..<colon])
                if (try? VMStore.validate(vm)) != nil {
                    self = .guest(vm: vm, path: String(operand[operand.index(after: colon)...]))
                    return
                }
            }
            self = .host(operand)
        }

        var isGuest: Bool { if case .guest = self { true } else { false } }
        var path: String {
            switch self {
            case .host(let path), .guest(_, let path): path
            }
        }
    }
}

public enum GuestCopyError: Error, Equatable, CustomStringConvertible {
    case tooFewOperands
    case noGuest
    case guestToGuest
    case mixedSources
    case severalGuests

    public var description: String {
        switch self {
        case .tooFewOperands: "cp needs at least a source and a destination"
        case .noGuest: "one side of cp must be a guest path, <vm>:<path>"
        case .guestToGuest: "cp copies between the host and a guest, not between guest paths"
        case .mixedSources: "cp sources must be all host paths or all guest paths"
        case .severalGuests: "cp sources must all be in the same VM"
        }
    }
}
