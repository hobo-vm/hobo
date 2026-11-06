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
    }

    @Test func settingTheGUIDLeavesTheRestOfTheSectorAlone() throws {
        var sector = try header()
        sector[100] = 0x55
        var parsed = try #require(GPTHeader(sector: sector))
        parsed.diskGUID = Data(repeating: 0xBB, count: 16)
        #expect(parsed.sector.count == 512)
        #expect(parsed.sector[92...] == sector[92...])
        #expect(parsed.alternateLBA == 0x1FF)
    }

    /// A slice of a larger read has indices that don't start at 0.
    @Test func readsASliceOfALargerBuffer() throws {
        let buffer = Data(repeating: 0xEE, count: 100) + (try header())
        let parsed = try #require(GPTHeader(sector: buffer[100...]))
        #expect(parsed.diskGUID == Data(repeating: 0xAA, count: 16))
        #expect(parsed.alternateLBA == 0x1FF)
    }

    @Test(arguments: [Data(), Data(repeating: 0, count: 512), Data("EFI PART".utf8)])
    func rejectsWhatIsntAHeader(_ sector: Data) {
        #expect(GPTHeader(sector: sector) == nil)
    }

    @Test(arguments: [(UInt8(10), UInt8(0)), (0x01, 0x02)])
    func rejectsAnImpossibleSize(_ low: UInt8, _ high: UInt8) throws {
        var sector = try header()
        sector[12] = low // 10 is under the header's fields; 0x201 is over the sector.
        sector[13] = high
        #expect(GPTHeader(sector: sector) == nil)
    }
}
