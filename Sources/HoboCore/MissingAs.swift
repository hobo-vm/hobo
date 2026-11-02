/// A flag that decodes as `Default.value` when its key is missing, so a field added to a stored or
/// wire format keeps synthesized `Codable` (one list of fields) while older files and peers leave
/// it out. Use through `MissingAsFalse` and `MissingAsTrue`.
@propertyWrapper
public struct MissingAs<Default: MissingDefault>: Codable, Equatable, Sendable {
    public var wrappedValue: Bool

    public init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }

    public init(from decoder: any Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(Bool.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

public protocol MissingDefault: Sendable { static var value: Bool { get } }
public enum DefaultFalse: MissingDefault { public static let value = false }
public enum DefaultTrue: MissingDefault { public static let value = true }
public typealias MissingAsFalse = MissingAs<DefaultFalse>
public typealias MissingAsTrue = MissingAs<DefaultTrue>

extension KeyedDecodingContainer {
    /// Chosen over the generic `decode` by synthesized `init(from:)`, and tolerates a missing key.
    public func decode<Default>(_ type: MissingAs<Default>.Type, forKey key: Key) throws -> MissingAs<Default> {
        try decodeIfPresent(type, forKey: key) ?? MissingAs(wrappedValue: Default.value)
    }
}

/// An array that decodes as empty when its key is missing, for the same reason as `MissingAs`.
@propertyWrapper
public struct MissingAsEmpty<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element]) { self.wrappedValue = wrappedValue }

    public init(from decoder: any Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode([Element].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode<Element>(_ type: MissingAsEmpty<Element>.Type, forKey key: Key) throws -> MissingAsEmpty<Element> {
        try decodeIfPresent(type, forKey: key) ?? MissingAsEmpty(wrappedValue: [])
    }
}
