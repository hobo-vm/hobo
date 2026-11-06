import Foundation
import HoboCore
import Testing

/// A real `hobo create` from the Windows on Arm ISO named by HOBO_WINDOWS_ISO, which Hobo can't
/// download, then everything that behaves differently on Windows. Opt-in on top of HOBO_INTEGRATION
/// (`HOBO_WINDOWS_ISO=<path> make integration-test`). VMs go to a temp `HOBO_VMS`, as in
/// `HoboVMIntegrationTests`. One test because the build takes 8 minutes; clones keep the steps apart.
@Suite(.enabled(if: integrationEnabled && environment["HOBO_WINDOWS_ISO"] != nil), .serialized)
struct WindowsIntegrationTests {
    @Test(.timeLimit(.minutes(60)))
    func windowsGuest() throws {
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let iso = try #require(environment["HOBO_WINDOWS_ISO"])
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-windows-\(UUID().uuidString)")
        let share = work.appending(path: "share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let session = Session(hobo: hobo, directory: work, vms: work.appending(path: "vms"))
        var started: [String] = []
        defer { for vm in started { _ = try? session.run(["stop", "--force", vm]) } }

        // The recipe, from init, with a step that sees its environment and fails the build if it can't.
        #expect(try session.run(["init", "--os", "windows", iso]).status == 0)
        let recipe = work.appending(path: "Hobo.toml")
        let provisioned = try String(contentsOf: recipe, encoding: .utf8) + """

            [[provision]]
            type   = "shell"
            inline = '''
            $env:GREETING | Set-Content C:\\Users\\vagrant\\provisioned.txt
            '''
            env = { GREETING = "it's here" }
            """
        try provisioned.write(to: recipe, atomically: true, encoding: .utf8)
        #expect(try session.run(["validate"]).status == 0)
        try #require(try session.run(["create", "base"]).status == 0)

        let config = try VMConfig.load(from: work.appending(path: "vms/base.hobovm/config.json"))
        #expect(config.os == .windows)
        #expect(config.guestOSVersion.contains("Windows"))

        // A clone runs alongside its source, each with its own address.
        #expect(try session.run(["clone", "base", "vm"]).status == 0)
        started.append("vm")
        try #require(try session.run(["start", "vm"]).status == 0)
        let list = try session.run(["list"]).text
        let address = try session.run(["ip", "vm"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(list.contains(address), "list shows the address")

        func powerShell(_ line: String, gui: Bool = false) throws -> Session.Result {
            try session.run(["exec", "vm"] + (gui ? ["--gui"] : []) + ["--", "powershell.exe", "-NoProfile", "-Command", line])
        }

        // Plain exec: output, exit statuses, quoting, PowerShell commands, binary output.
        #expect(try powerShell(#"Get-Content C:\Users\vagrant\provisioned.txt"#).text.contains("it's here"))
        #expect(try session.run(["exec", "vm", "--", "cmd.exe", "/c", "exit 7"]).status == 7)
        #expect(try session.run(["exec", "vm", "--", "nosuchprogram"]).status == 127)
        #expect(try session.run(["exec", "vm", "--", "Write-Output", #"it's "quoted""#]).text.contains(#"it's "quoted""#))
        #expect(try session.run(["exec", "vm", "--", "Get-Date", "-Format", "yyyy"]).text.count >= 4)
        let binary = try powerShell("[Console]::OpenStandardOutput().Write([byte[]](0,1,13,10,255),0,5)")
        #expect(binary.data == Data([0, 1, 13, 10, 255]))

        // The guest's clock and zone agree with the host's.
        let guestSeconds = try powerShell("[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()").text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(abs((Double(guestSeconds) ?? 0) - Date.now.timeIntervalSince1970) < 60)

        // --gui runs on the desktop, comes back with its status, and can drive an app.
        #expect(try Int(powerShell("(Get-Process -Id $PID).SessionId", gui: true).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 0)
        #expect(try session.run(["exec", "vm", "--gui", "--", "cmd.exe", "/c", "exit 9"]).status == 9)
        let automation = #"""
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            Start-Process notepad.exe; Start-Sleep 5
            $root = [Windows.Automation.AutomationElement]::RootElement
            $window = $root.FindFirst('Children', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ClassNameProperty, 'Notepad')))
            $document = $window.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Document)))
            $value = $document.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
            $value.SetValue('typed by automation')
            $value.Current.Value
            """#
        #expect(try powerShell(automation, gui: true).text.contains("typed by automation"))

        // Screenshot: a PNG of the display, at the size create set.
        let shot = work.appending(path: "shot.png")
        #expect(try session.run(["screenshot", "vm", "--output", shot.path]).status == 0)
        let png = try Data(contentsOf: shot)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(png[16..<24] == Data([0, 0, 0x07, 0x80, 0, 0, 0x04, 0xB0]), "1920×1200")

        // Copies, both ways, to a Windows path.
        let copy = work.appending(path: "copy.txt")
        try "copied".write(to: copy, atomically: true, encoding: .utf8)
        #expect(try session.run(["cp", copy.path, "vm:C:/Users/vagrant/copy.txt"]).status == 0)
        let back = work.appending(path: "back.txt")
        #expect(try session.run(["cp", "vm:C:/Users/vagrant/copy.txt", back.path]).status == 0)
        #expect(try String(contentsOf: back, encoding: .utf8) == "copied")

        // Cancelling ends the command in the guest, and leaves nothing of a --gui command behind.
        for gui in [false, true] {
            let tag = gui ? 7001 : 7000
            let process = try session.start(["exec", "vm"] + (gui ? ["--gui"] : []) + ["--", "powershell.exe", "-Command", "Start-Sleep \(tag)"])
            Thread.sleep(forTimeInterval: 15)
            process.interrupt()
            process.waitUntilExit()
            Thread.sleep(forTimeInterval: 15)
            let left = #"@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Start-Sleep \#(tag)' -and $_.CommandLine -notmatch 'CimInstance' }).Count + @(Get-ScheduledTask hobo-gui* -EA 0).Count + @(dir C:\ProgramData\Hobo\gui).Count"#
            #expect(try powerShell(left).text.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "gui \(gui)")
        }

        // Suspend and resume: the guest's watchdog gets the network back.
        #expect(try session.run(["suspend", "vm"]).status == 0)
        #expect(try session.run(["start", "vm"]).status == 0)
        #expect(try powerShell("(Test-NetConnection 8.8.8.8 -Port 53).TcpTestSucceeded").text.contains("True"))

        // A live snapshot brings back the disk as it was, with a network.
        #expect(try session.run(["snapshot", "save", "vm", "live"]).status == 0)
        #expect(try powerShell(#"'later' | Set-Content C:\later.txt"#).status == 0)
        #expect(try session.run(["snapshot", "restore", "--force", "vm", "live"]).status == 0)
        #expect(try powerShell(#"Test-Path C:\later.txt"#).text.contains("False"))
        #expect(try powerShell("(Test-NetConnection 8.8.8.8 -Port 53).TcpTestSucceeded").text.contains("True"))
        #expect(try session.run(["snapshot", "delete", "vm", "live"]).status == 0)
        #expect(try session.run(["stop", "vm"]).status == 0)

        // Growing the disk and a persistent share: Windows still boots, and takes the new space.
        try "from host".write(to: share.appending(path: "host.txt"), atomically: true, encoding: .utf8)
        #expect(try session.run(["set", "vm", "--disk", "80GB", "--share", share.path]).status == 0)
        try #require(try session.run(["start", "vm"]).status == 0)
        let size = try powerShell("(Get-Volume -DriveLetter C).Size").text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((UInt64(size) ?? 0) > 70 << 30)
        #expect(try powerShell(#"Get-Content Z:\share\host.txt"#).text.contains("from host"))
        #expect(try powerShell(#"'from guest' | Set-Content Z:\share\guest.txt"#).status == 0)
        #expect(FileManager.default.fileExists(atPath: share.appending(path: "guest.txt").path))
        #expect(try session.run(["stop", "vm"]).status == 0)

        // A read-only share for one run.
        let readOnly = work.appending(path: "readonly")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try "kept".write(to: readOnly.appending(path: "kept.txt"), atomically: true, encoding: .utf8)
        try #require(try session.run(["start", "vm", "--share", "\(readOnly.path):ro"]).status == 0)
        #expect(try powerShell(#"Set-Content Z:\readonly\denied.txt 'x'"#).status != 0)
        #expect(try powerShell(#"Test-Path Z:\readonly\kept.txt"#).text.contains("True"))
        #expect(try session.run(["stop", "vm"]).status == 0)

        // An ephemeral clone goes when it stops.
        let ephemeral = try session.run(["start", "base", "--ephemeral", "--json"])
        #expect(ephemeral.status == 0)
        let name = try #require(ephemeral.text.firstMatch(of: /"name":"([^"]+)"/)?.1)
        started.append(String(name))
        #expect(try session.run(["stop", String(name)]).status == 0)
        #expect(!(try session.run(["list"]).text.contains(String(name))))
    }

    private struct Session {
        struct Result {
            var status: Int32
            var data: Data
            var text: String { String(decoding: data, as: UTF8.self) }
        }

        var hobo: String
        var directory: URL
        var vms: URL

        func start(_ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(filePath: hobo)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = environment.merging(["HOBO_VMS": vms.path]) { $1 }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            return process
        }

        func run(_ arguments: [String]) throws -> Result {
            let process = Process()
            process.executableURL = URL(filePath: hobo)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = environment.merging(["HOBO_VMS": vms.path]) { $1 }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(status: process.terminationStatus, data: data)
        }
    }
}
