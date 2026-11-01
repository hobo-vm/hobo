import Foundation

/// A byte count written in a recipe as `"512MB"`, `"8GB"` etc. (binary units).
public struct ByteSize: Equatable, Sendable, Decodable {
    public var bytes: UInt64

    public init(bytes: UInt64) { self.bytes = bytes }

    /// Largest first, so `"8GB"` matches `GB` rather than `B`.
    private static let units: [(suffix: String, multiplier: UInt64)] = [
        ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10), ("B", 1),
    ]

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let (suffix, multiplier) = Self.units.first(where: { trimmed.hasSuffix($0.suffix) }),
              let value = UInt64(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)),
              case (let product, false) = value.multipliedReportingOverflow(by: multiplier)
        else { throw RecipeError.invalidSize(text) }
        bytes = product
    }

    public init(from decoder: Decoder) throws {
        try self.init(parsing: decoder.singleValueContainer().decode(String.self))
    }
}

extension ByteSize: CustomStringConvertible {
    /// The largest unit that divides evenly, e.g. `"8GB"`; `"0B"` for zero.
    public var description: String {
        let (suffix, multiplier) = Self.units.first { bytes >= $0.multiplier && bytes % $0.multiplier == 0 } ?? ("B", 1)
        return "\(bytes / multiplier)\(suffix)"
    }
}
