import Foundation

/// Reads and edits a GUID Partition Table header, one sector of a disk.
public struct GPTHeader: Equatable, Sendable {
    public private(set) var sector: Data

    private static let signature = Data("EFI PART".utf8)
    private static let sizeOffset = 12
    private static let checksumOffset = 16
    private static let alternateOffset = 32
    private static let diskGUIDRange = 56..<72

    /// Nil unless `sector` starts with a GPT header of a sensible size.
    public init?(sector: Data) {
        let sector = Data(sector) // So that its indices start at 0.
        guard sector.prefix(8) == Self.signature, sector.count >= 92 else { return nil }
        self.sector = sector
        guard (92...sector.count).contains(size) else { return nil }
    }

    /// The sector of the other copy of this header.
    public var alternateLBA: UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(sector[Self.alternateOffset + $1]) << (8 * $1) }
    }

    public var diskGUID: Data {
        get { sector.subdata(in: Self.diskGUIDRange) }
        set {
            precondition(newValue.count == Self.diskGUIDRange.count)
            sector.replaceSubrange(Self.diskGUIDRange, with: newValue)
            updateChecksum()
        }
    }

    private var size: Int {
        (0..<4).reduce(0) { $0 | Int(sector[Self.sizeOffset + $1]) << (8 * $1) }
    }

    /// The header's CRC-32, which covers its own bytes with this field taken as zero.
    private mutating func updateChecksum() {
        sector.replaceSubrange(Self.checksumOffset..<(Self.checksumOffset + 4), with: Data(repeating: 0, count: 4))
        let checksum = Self.crc32(sector.prefix(size))
        sector.replaceSubrange(
            Self.checksumOffset..<(Self.checksumOffset + 4),
            with: (0..<4).map { UInt8(truncatingIfNeeded: checksum >> (8 * $0)) }
        )
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        ~bytes.reduce(UInt32.max) { crc, byte in
            (0..<8).reduce(crc ^ UInt32(byte)) { value, _ in
                value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
        }
    }
}
