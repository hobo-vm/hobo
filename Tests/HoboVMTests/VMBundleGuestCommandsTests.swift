import Foundation
import HoboControl
import HoboCore
import Testing
@testable import HoboVM

/// The guest commands each kind of bundle answers with: the VM process runs whichever its guest's
/// bundle gives. Needs no VM.
@Suite struct VMBundleGuestCommandsTests {
    /// What hobo-agent runs for a plain `exec`, against a local shell standing in for the guest's.
    @Test func aPOSIXAgentCommandRunsTheCommandQuoted() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", MacVMBundle.agentCommand(["printf", "%s", "it's a b"], gui: false)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: stdout, as: UTF8.self) == "it's a b")
    }

    @Test func macOSAndLinuxShareThePOSIXWays() {
        #expect(LinuxVMBundle.agentCommand(["a"], gui: false) == MacVMBundle.agentCommand(["a"], gui: false))
        for bundle in [MacVMBundle.self, LinuxVMBundle.self] as [any VMBundle.Type] {
            #expect(bundle.shutdownCommand == "sudo -n shutdown -h now")
            // A local, since #expect can't take a static member through an existential metatype.
            let startsInDesktop = bundle.agentStartsInDesktop
            #expect(!startsInDesktop)
        }
        #expect(MacVMBundle.agentCommand(["a"], gui: true) == MacVMBundle.guiExecScript(["a"]))
        #expect(LinuxVMBundle.agentCommand(["a"], gui: true) == LinuxVMBundle.guiExecScript(["a"]))
    }

    /// A Windows guest has no POSIX shell, so none of those defaults may reach it, and its agent
    /// enters the desktop session itself.
    @Test func windowsGoesThroughItsOwnScripts() {
        for gui in [false, true] {
            #expect(WindowsVMBundle.agentCommand(["a"], gui: gui) == WindowsGuest.execCommand(["a"]))
        }
        #expect(WindowsVMBundle.agentStartsInDesktop)
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
        let startsInDesktop = windows.agentStartsInDesktop
        #expect(startsInDesktop)
        #expect(windows.agentCommand(["a"], gui: false) == WindowsGuest.execCommand(["a"]))
        #expect(try vmBundle(at: directory, config: config(.macOS)) is MacVMBundle)
        #expect(try vmBundle(at: directory, config: config(.linux)) is LinuxVMBundle)
    }

    /// virtio-win's viogpudo stays at its startup mode, which the window scales; the patched one
    /// (`[windows] resizable_display`) gets every other guest's size, and follows the window.
    @Test func onlyAResizableWindowsDisplayLeaves1024x768() throws {
        let directory = URL(filePath: "/nowhere")
        let fixed = try vmBundle(at: directory, config: config(.windows))
        #expect(fixed.displayPixels == CGSize(width: 1024, height: 768))
        #expect(!fixed.displayFollowsWindow)
        let resizable = try vmBundle(at: directory, config: config(.windows, resizableDisplay: true))
        #expect(resizable.displayPixels == GuestDisplay.pixels)
        #expect(resizable.displayFollowsWindow)
    }

    private func config(_ os: VMConfig.OS, resizableDisplay: Bool = false) -> VMConfig {
        VMConfig(
            os: os, cpus: 4, memory: 8 << 30, disk: 64 << 30, macAddress: "5a:00:00:00:00:01", guestOSVersion: "",
            created: Date(timeIntervalSince1970: 0), recipeSHA256: "", sourceSHA256: "", resizableDisplay: resizableDisplay
        )
    }
}
