import Foundation
import Testing
@testable import HoboCore

@Suite struct LaunchdTests {
    @Test func parsesTheJobList() {
        let jobs = Launchd.parseList("""
        PID\tStatus\tLabel
        812\t0\tcom.apple.Finder
        -\t0\tcom.hobo.vm.0123abcd.dev
        -\t-9\tcom.hobo.vm.0123abcd.killed
        4242\t1\tcom.hobo.vm.0123abcd.with\ttab
        not a row
        """)
        #expect(jobs == [
            .init(label: "com.apple.Finder", pid: 812, lastExitStatus: 0),
            .init(label: "com.hobo.vm.0123abcd.dev", pid: nil, lastExitStatus: 0),
            .init(label: "com.hobo.vm.0123abcd.killed", pid: nil, lastExitStatus: -9),
            .init(label: "com.hobo.vm.0123abcd.with\ttab", pid: 4242, lastExitStatus: 1),
        ])
    }

    @Test func jobsKeepsOnlyHobosVMs() {
        let launchd = Launchd { _ in (0, "PID\tStatus\tLabel\n812\t0\tcom.apple.Finder\n7\t0\tcom.hobo.vm.x.dev\n") }
        #expect(launchd.jobs() == ["com.hobo.vm.x.dev": .init(label: "com.hobo.vm.x.dev", pid: 7, lastExitStatus: 0)])
    }

    @Test func failingLaunchctlListsNothing() {
        #expect(Launchd { _ in (1, "") }.jobs().isEmpty)
        #expect(Launchd { _ in throw CocoaError(.fileNoSuchFile) }.jobs().isEmpty)
    }

    @Test func bootstrapReportsFailure() {
        let launchd = Launchd { _ in (5, "Bootstrap failed: 5: Input/output error\n") }
        #expect(throws: LaunchdError.self) { try launchd.bootstrap(URL(filePath: "/tmp/x.plist")) }
    }

    @Test func plistIsATransientAgent() throws {
        let data = try Launchd.plist(
            label: "com.hobo.vm.x.dev", arguments: ["/bin/hobo", "_vm-run", "dev"],
            environment: ["HOBO_VMS": "/vms"], log: URL(filePath: "/logs/x.log")
        )
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.hobo.vm.x.dev")
        #expect(plist["ProgramArguments"] as? [String] == ["/bin/hobo", "_vm-run", "dev"])
        #expect(plist["EnvironmentVariables"] as? [String: String] == ["HOBO_VMS": "/vms"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] == nil)
        #expect(plist["StandardOutPath"] as? String == "/logs/x.log")
        #expect(plist["StandardErrorPath"] as? String == "/logs/x.log")
    }
}
