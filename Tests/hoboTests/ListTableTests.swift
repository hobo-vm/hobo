import Foundation
import Testing
import HoboControl
@testable import HoboCore
@testable import hobo

struct ListTableTests {
    private let config = VMConfig(
        engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
        guestOSVersion: "27.2.0 (26B123)", created: .now, recipeSHA256: "", sourceSHA256: ""
    )

    private func snapshot(_ tag: String, live: Bool = false, uniqueBytes: UInt64) -> Snapshot {
        Snapshot(tag: tag, record: SnapshotRecord(config: config, createdAt: .now), savedStateBytes: live ? 1 : nil, uniqueBytes: uniqueBytes)
    }

    private func summary(_ status: VMStore.Status) -> VMSummary {
        VMSummary(VMStore.VM(name: "dev", bundle: URL(filePath: "/dev.hobovm"), status: status, allocatedBytes: 1 << 30))
    }

    @Test func aRowsStateSaysWhatEachStateHasToSay() {
        func state(_ status: VMStore.Status) -> String { List.row(summary(status))[1] }
        #expect(state(.stopped(config)) == "stopped")
        #expect(state(.suspended(config, SavedState(bytes: 2 << 30, run: nil))) == "suspended (2 GB)")
        #expect(state(.crashed(config, exitStatus: 1)) == "crashed (exit 1)")
        #expect(state(.crashed(config, exitStatus: -9)) == "crashed (signal 9)")
    }

    @Test func anEphemeralVMsStateSaysSo() {
        var ephemeral = config
        ephemeral.ephemeral = true
        #expect(List.row(summary(.stopped(ephemeral)))[1] == "stopped, ephemeral")
        #expect(List.row(summary(.running(ephemeral, pid: 4242)))[1] == "running, ephemeral")
    }

    @Test func anEphemeralRowSaysWhereItsIdleTimeoutStands() {
        var ephemeral = config
        ephemeral.ephemeral = true
        func state(
            timeout: Int? = 1800, remaining: Int? = nil, windowShown: Bool? = false, phase: String? = nil
        ) -> String {
            var running = summary(.running(ephemeral, pid: 4242))
            running.idleTimeoutSeconds = timeout
            running.idleSecondsRemaining = remaining
            running.windowShown = windowShown
            running.phase = phase
            return List.row(running)[1]
        }
        #expect(state(remaining: 1680) == "running, ephemeral, 28m left")
        #expect(state() == "running, ephemeral, busy", "it has a timeout, but nothing is counting")
        #expect(state(timeout: nil) == "running, ephemeral, no timeout")
        #expect(state(windowShown: true) == "running (window), ephemeral", "the window explains the hold")
        #expect(state(windowShown: nil) == "running, ephemeral", "its process didn't answer, so nothing is known")
        #expect(state(remaining: 60, phase: "starting") == "starting, ephemeral", "no countdown until the boot sequence ends")
        #expect(state(phase: "stopping") == "stopping, ephemeral")
    }

    @Test func aNormalVMsRowHasNoIdleTimeout() {
        var running = summary(.running(config, pid: 4242))
        running.windowShown = false
        #expect(List.row(running)[1] == "running")
    }

    @Test(arguments: [(1, "1s left"), (59, "59s left"), (60, "1m left"), (61, "2m left"), (1680, "28m left"), (1681, "29m left"), (3600, "1h left"), (5400, "1h 30m left"), (7200, "2h left")])
    func timeLeftRoundsUpToTheMinuteWithSecondsUnderOne(seconds: Int, text: String) {
        var ephemeral = config
        ephemeral.ephemeral = true
        var running = summary(.running(ephemeral, pid: 4242))
        running.windowShown = false
        running.idleTimeoutSeconds = 7200
        running.idleSecondsRemaining = seconds
        #expect(List.row(running)[1] == "running, ephemeral, \(text)")
    }

    @Test func startSaysTheAddressAndTheIdleTimeout() {
        #expect(Start.details(nil) == "")
        #expect(Start.details(VMRunStatus(state: .running, pid: 1)) == "")
        #expect(Start.details(VMRunStatus(state: .running, pid: 1, ipAddress: "192.168.64.5")) == " (192.168.64.5)")
        #expect(Start.details(VMRunStatus(state: .running, pid: 1, ipAddress: "192.168.64.5", idleTimeoutSeconds: 1800))
            == " (192.168.64.5); deleted after 30m idle")
    }

    @Test func aRunningRowsStateIsWhatItsProcessSays() {
        func state(windowShown: Bool? = nil, phase: String? = nil, detail: String? = nil) -> String {
            var running = summary(.running(config, pid: 4242))
            running.windowShown = windowShown
            running.phase = phase
            running.phaseDetail = detail
            return List.row(running)[1]
        }
        #expect(state() == "running")
        #expect(state(windowShown: false) == "running")
        #expect(state(windowShown: true) == "running (window)")
        #expect(state(windowShown: true, phase: "stopping", detail: "saving state") == "stopping (saving state)")
        #expect(state(phase: "starting") == "starting")
    }

    @Test func aRowWithAConfigFillsItsColumnsFromIt() {
        let cells = List.row(summary(.stopped(config)))
        #expect(cells == ["dev", "stopped", config.osDescription, "4", "8 GB", "1 GB / 80 GB"])
    }

    /// The table lines its columns up by zipping, so a row one cell short would lose a column silently.
    @Test func aRowWithNoConfigKeepsEveryColumn() {
        for (status, state) in [(VMStore.Status.failed, "failed"), (.broken, "broken"), (.building(pid: 7), "building")] {
            #expect(List.row(summary(status)) == ["dev", state, "—", "—", "—", "1 GB / —"])
        }
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
