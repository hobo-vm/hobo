import Foundation
import HoboCore
import Testing
@testable import hobo

struct ListTableTests {
    private func snapshot(_ tag: String, live: Bool = false, uniqueBytes: UInt64) -> Snapshot {
        let config = VMConfig(
            engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
            guestOSVersion: "27.2.0 (26B123)", created: .now, recipeSHA256: "", sourceSHA256: ""
        )
        return Snapshot(tag: tag, record: SnapshotRecord(config: config, createdAt: .now), savedStateBytes: live ? 1 : nil, uniqueBytes: uniqueBytes)
    }

    @Test func aSnapshotsCellIsADashOnlyWithNothingToReport() {
        #expect(List.snapshotsCell(count: 0, bytes: 0) == "—")
        #expect(List.snapshotsCell(count: 2, bytes: 1 << 30) == "2 (1 GB)")
        #expect(List.snapshotsCell(count: 2, bytes: 0).hasPrefix("2 ("))
        #expect(List.snapshotsCell(count: 0, bytes: 1 << 20) == "0 (1 MB)") // What a failed save left.
    }

    @Test func verboseListsEachVMsSnapshotsUnderItsLine() throws {
        let rows = [["NAME", "STATE"], ["longname", "stopped"], ["bare", "stopped"], ["TOTAL", ""]]
        let lines = List.tableWithSnapshots(rows, snapshots: [
            [snapshot("clean", uniqueBytes: 1 << 20), snapshot("later", live: true, uniqueBytes: 2 << 20)],
            [],
        ]).components(separatedBy: "\n")

        #expect(lines.count == 6)
        #expect(lines[0].hasPrefix("NAME"))
        #expect(lines[1].hasPrefix("longname"))
        #expect(lines[4].hasPrefix("bare"))
        #expect(lines[5].hasPrefix("TOTAL"))
        // Lined up under STATE, and each with its kind and what it alone holds.
        let stateColumn = try #require(lines[0].range(of: "STATE")).lowerBound.utf16Offset(in: lines[0])
        let indent = String(repeating: " ", count: stateColumn)
        #expect(lines[2].hasPrefix(indent + "clean") && lines[2].contains("disk") && lines[2].hasSuffix("1 MB"))
        #expect(lines[3].hasPrefix(indent + "later") && lines[3].contains("live") && lines[3].hasSuffix("2 MB"))
    }

    @Test func verboseWithNoSnapshotsIsThePlainTable() {
        let rows = [["NAME", "STATE"], ["dev", "stopped"], ["TOTAL", ""]]
        let text = List.tableWithSnapshots(rows, snapshots: [[]])
        #expect(text.components(separatedBy: "\n").count == 3)
        #expect(text.hasSuffix("TOTAL"))
    }
}
