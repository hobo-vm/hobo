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

    @Test func aMacGUILinePrintsTheMarkerBeforeItsScript() {
        #expect(MacVMBundle.guiExecLine(["a"], marker: "m:") == "echo m:$$; " + MacVMBundle.guiExecScript(["a"]))
    }

    @Test func aLinuxGUILinePrintsTheMarkerBeforeItsScript() {
        #expect(LinuxVMBundle.guiExecLine(["a"], marker: "m:") == "echo m:$$; " + LinuxVMBundle.guiExecScript(["a"]))
    }

    /// A Windows guest has no POSIX shell, so none of those defaults may reach it.
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
        let bundle = try vmBundle(at: directory, config: config(.windows))
        let windows = type(of: bundle)
        #expect(bundle is WindowsVMBundle)
        #expect(windows.shutdownCommand == WindowsGuest.shutdownCommand)
        #expect(windows.execLine(["a"], marker: "m:") == WindowsGuest.execLine(["a"], marker: "m:"))
        #expect(try vmBundle(at: directory, config: config(.macOS)) is MacVMBundle)
        #expect(try vmBundle(at: directory, config: config(.linux)) is LinuxVMBundle)
    }

    /// virtio-win's viogpudo stays at its startup mode; the patched one (`[windows] resizable_display`)
    /// gets every other guest's size. Either way the window scales it, since nothing in the guest
    /// applies a new size yet.
    @Test func onlyAResizableWindowsDisplayLeaves1024x768() throws {
        let directory = URL(filePath: "/nowhere")
        let fixed = try vmBundle(at: directory, config: config(.windows))
        #expect(fixed.displayPixels == CGSize(width: 1024, height: 768))
        #expect(!fixed.displayFollowsWindow)
        let resizable = try vmBundle(at: directory, config: config(.windows, resizableDisplay: true))
        #expect(resizable.displayPixels == GuestDisplay.pixels)
        #expect(!resizable.displayFollowsWindow)
    }

    private func config(_ os: VMConfig.OS, resizableDisplay: Bool = false) -> VMConfig {
        VMConfig(
            os: os, cpus: 4, memory: 8 << 30, disk: 64 << 30, macAddress: "5a:00:00:00:00:01", guestOSVersion: "",
            created: Date(timeIntervalSince1970: 0), recipeSHA256: "", sourceSHA256: "", resizableDisplay: resizableDisplay
        )
    }
}
