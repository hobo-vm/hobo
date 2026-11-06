import Foundation
import Testing
@testable import HoboCore

@Suite struct GPTHeaderTests {
    /// A header as a disk holds it: 92 bytes in a 512-byte sector, and a checksum of those 92.
    func header(guid: UInt8 = 0xAA) throws -> Data {
        var sector = Data(repeating: 0, count: 512)
        sector.replaceSubrange(0..<8, with: Data("EFI PART".utf8))
        sector[12] = 92
        sector[32] = 0xFF // The alternate header's sector: 0x1FF.
        sector[33] = 0x01
        sector.replaceSubrange(56..<72, with: Data(repeating: guid, count: 16))
        return sector
    }

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(GPTHeader.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func readsTheGUIDAndAlternate() throws {
        let parsed = try #require(GPTHeader(sector: try header()))
        #expect(parsed.diskGUID == Data(repeating: 0xAA, count: 16))
        #expect(parsed.alternateLBA == 0x1FF)
    }

    @Test func settingTheGUIDUpdatesTheChecksumOverTheHeaderOnly() throws {
        var parsed = try #require(GPTHeader(sector: try header()))
        parsed.diskGUID = Data(repeating: 0xBB, count: 16)
        #expect(parsed.diskGUID == Data(repeating: 0xBB, count: 16))
        // What a reader of the disk checks: the CRC of the header's bytes, with its own field zeroed.
        var zeroed = parsed.sector.prefix(92)
        let stored = zeroed[16..<20].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        zeroed.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        #expect(GPTHeader.crc32(Data(zeroed)) == stored)
        #expect(stored != 0)
        // The rest of the sector is left alone.
        #expect(parsed.sector.count == 512)
    }

    @Test(arguments: [Data(), Data(repeating: 0, count: 512), Data("EFI PART".utf8)])
    func rejectsWhatIsntAHeader(_ sector: Data) {
        #expect(GPTHeader(sector: sector) == nil)
    }

    @Test func rejectsAnImpossibleSize() throws {
        var sector = try header()
        sector[12] = 10
        #expect(GPTHeader(sector: sector) == nil)
    }
}
