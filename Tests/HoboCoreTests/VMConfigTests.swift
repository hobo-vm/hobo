import Foundation
import Testing
@testable import HoboCore

@Suite struct VMConfigTests {
    static let json = """
        {"cpus":4,"created":"2026-11-01T12:00:00Z","disk":85899345920,"engine":"vz","guestOSVersion":"27.2.0 (26B123)",
         "macAddress":"aa:bb:cc:dd:ee:ff","memory":8589934592,"os":"macOS","recipeSHA256":"r","sourceSHA256":"s"%@}
        """

    /// Bundles built before `[security]` have no sip/amfi keys; they were built with both on.
    @Test func olderConfigsHaveSIPAndAMFIOn() throws {
        let config = try VMConfig.decoder.decode(VMConfig.self, from: Data(Self.json.replacingOccurrences(of: "%@", with: "").utf8))
        #expect(config.sip && config.amfi)
    }

    /// Bundles from before `hobo set --disk` have no pending grow.
    @Test func olderConfigsHaveNoPendingDiskGrow() throws {
        let config = try VMConfig.decoder.decode(VMConfig.self, from: Data(Self.json.replacingOccurrences(of: "%@", with: "").utf8))
        #expect(!config.diskGrowPending)
        #expect(config.shares.isEmpty)
        var pending = config
        pending.diskGrowPending = true
        pending.shares = [VMShare(name: "src", path: "/src", readOnly: true)]
        #expect(try VMConfig.decoder.decode(VMConfig.self, from: VMConfig.encoder.encode(pending)) == pending)
    }

    @Test func securityRoundTrips() throws {
        let config = try VMConfig.decoder.decode(
            VMConfig.self, from: Data(Self.json.replacingOccurrences(of: "%@", with: #","sip":false,"amfi":false"#).utf8)
        )
        #expect(!config.sip && !config.amfi)
        let again = try VMConfig.decoder.decode(VMConfig.self, from: VMConfig.encoder.encode(config))
        #expect(again == config)
    }
}
