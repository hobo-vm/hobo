import Foundation
import HoboControl
import HoboCore
import Synchronization
import Testing
@testable import HoboVM

/// The guest commands each kind of bundle answers with: the VM process runs whichever its guest's
/// bundle gives. Needs no VM.
@Suite struct VMBundleGuestCommandsTests {
    /// What `GuestSSH.exec` does with an `execLine`, against a local shell standing in for the guest's.
    @Test func aPOSIXExecLineHandsOverItsPIDThenRunsTheCommandQuoted() throws {
        let received = Mutex(Data())
        let marker = GuestSSH.PIDMarker { _, data in received.withLock { $0.append(data) } }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", MacVMBundle.execLine(["printf", "%s", "it's a b"], marker: marker.marker)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        marker.receive(.stdout, stdout)
        marker.finish()
        #expect(marker.pid == process.processIdentifier, "exec keeps the shell's PID")
        #expect(received.withLock { String(decoding: $0, as: UTF8.self) } == "it's a b")
    }

    @Test func macOSAndLinuxShareThePOSIXWays() {
        #expect(LinuxVMBundle.execLine(["a"], marker: "m:") == MacVMBundle.execLine(["a"], marker: "m:"))
        for bundle in [MacVMBundle.self, LinuxVMBundle.self] as [any VMBundle.Type] {
            #expect(bundle.shutdownCommand == "sudo -n shutdown -h now")
            #expect(bundle.cancelCommand(pid: 42) == "kill -TERM -- -42")
        }
    }

    @Test func aMacGUILinePrintsTheMarkerBeforeItsScript() throws {
        let script = try #require(MacVMBundle.guiExecScript(["a"]))
        #expect(MacVMBundle.guiExecLine(["a"], marker: "m:") == "echo m:$$; " + script)
    }

    /// What `exec --gui` refuses on.
    @Test func linuxHasNoGUILine() {
        #expect(LinuxVMBundle.guiExecLine(["a"], marker: "m:") == nil)
    }

    /// A Windows guest has no POSIX shell, so none of those defaults may reach it, and it has a GUI
    /// line even with no script.
    @Test func windowsGoesThroughItsOwnScripts() {
        #expect(WindowsVMBundle.execLine(["a"], marker: "m:") == WindowsGuest.execLine(["a"], marker: "m:"))
        #expect(WindowsVMBundle.guiExecLine(["a"], marker: "m:") == WindowsGuest.guiExecLine(["a"], marker: "m:"))
        #expect(WindowsVMBundle.cancelCommand(pid: 42) == WindowsGuest.cancelCommand(pid: 42))
        #expect(WindowsVMBundle.shutdownCommand == WindowsGuest.shutdownCommand)
    }

    /// Through the protocol, as the VM process calls them: a requirement a bundle's method doesn't
    /// match would silently leave the POSIX default in place.
    @Test func aBundleFromDiskIsTheOneForItsOS() throws {
        let directory = URL(filePath: "/nowhere")
        let bundle = try vmBundle(at: directory, os: .windows)
        let windows = type(of: bundle)
        #expect(bundle is WindowsVMBundle)
        #expect(windows.shutdownCommand == WindowsGuest.shutdownCommand)
        #expect(windows.execLine(["a"], marker: "m:") == WindowsGuest.execLine(["a"], marker: "m:"))
        #expect(try vmBundle(at: directory, os: .macOS) is MacVMBundle)
        #expect(try vmBundle(at: directory, os: .linux) is LinuxVMBundle)
    }
}
