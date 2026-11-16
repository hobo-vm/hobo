import Foundation
import HoboCore
import Testing

/// A real `hobo create` from the Windows on Arm ISO named by HOBO_WINDOWS_ISO, which Hobo can't
/// download, then everything that behaves differently on Windows. Opt-in on top of HOBO_INTEGRATION
/// (`HOBO_WINDOWS_ISO=<path> make integration-test`). VMs go to a temp `HOBO_VMS`, as in
/// `HoboVMIntegrationTests`. One test per build, since a build takes 8 minutes; clones keep the steps apart.
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

        // The recipe, from init, with a step that sees its environment and its own text, and fails the build if it can't.
        #expect(try session.run(["init", "--os", "windows", iso]).status == 0)
        let recipe = work.appending(path: "Hobo.toml")
        let provisioned = try String(contentsOf: recipe, encoding: .utf8) + """

            [[provision]]
            type   = "shell"
            inline = '''
            if ('é'.Length -ne 1) { exit 1 }
            $env:GREETING | Set-Content C:\\Users\\hobo\\provisioned.txt
            '''
            env = { GREETING = "it's here" }

            [[provision]]
            type = "shell"
            path = "bomless.ps1"
            """
        try provisioned.write(to: recipe, atomically: true, encoding: .utf8)
        // UTF-8 with no byte order mark, as Mac editors write it: PowerShell must still read the é as one letter.
        try "if ('é'.Length -ne 1) { exit 3 }\n".write(to: work.appending(path: "bomless.ps1"), atomically: true, encoding: .utf8)
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

        // Setup has finished: hobo stays logged on past the point where an unfinished OOBE logs it
        // off (about a minute after logon) and clears the auto-login settings, here and after a restart.
        func staysLoggedOn(_ when: String) throws {
            Thread.sleep(forTimeInterval: 90)
            #expect(try powerShell("cmd.exe /c 'quser 2>nul'").text.contains("hobo"), "hobo has a session \(when)")
            let autoLogon = #"(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').AutoAdminLogon"#
            #expect(try powerShell(autoLogon).text.contains("1"), "auto-login is still on \(when)")
        }
        try staysLoggedOn("on the first boot")
        #expect(try session.run(["stop", "vm"]).status == 0)
        try #require(try session.run(["start", "vm"]).status == 0)
        try staysLoggedOn("after a restart")

        // Plain exec: output, exit statuses, quoting, PowerShell commands, binary output.
        #expect(try powerShell(#"Get-Content C:\Users\hobo\provisioned.txt"#).text.contains("it's here"))
        #expect(try session.run(["exec", "vm", "--", "cmd.exe", "/c", "exit 7"]).status == 7)
        #expect(try session.run(["exec", "vm", "--", "nosuchprogram"]).status == 127)
        // Found, but not something Windows can start.
        for gui in [[], ["--gui"]] {
            #expect(try session.run(["exec", "vm"] + gui + ["--", #"C:\Windows\win.ini"#]).status == 126, "\(gui)")
        }
        #expect(try session.run(["exec", "vm", "--", "Write-Output", #"it's "quoted""#]).text.contains(#"it's "quoted""#))
        #expect(try session.run(["exec", "vm", "--", "Write-Output", "it\u{2019}s curly"]).text.contains("it\u{2019}s curly"))
        #expect(try session.run(["exec", "vm", "--gui", "--", "Write-Output", "it\u{2019}s curly"]).text.contains("it\u{2019}s curly"))
        #expect(try session.run(["exec", "vm", "--", "Get-Date", "-Format", "yyyy"]).text.count >= 4)
        #expect(try session.run(["exec", "vm", "--", "Get-Item", #"C:\nosuchfile"#]).status == 1)
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

        // Screenshot: a PNG of the desktop, at virtio-win's viogpudo's fixed size. This sees Windows'
        // desktop, not the window, so it can't tell whether the window is showing it.
        let shot = work.appending(path: "shot.png")
        #expect(try session.run(["screenshot", "vm", "--output", shot.path]).status == 0)
        let png = try Data(contentsOf: shot)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(png[16..<24] == Data([0, 0, 0x04, 0x00, 0, 0, 0x03, 0x00]), "1024×768")

        // SSH is still there for people.
        #expect(try session.run(["ssh", "vm", "--", "whoami"]).text.lowercased().contains("hobo"))

        // Copies, both ways, to a Windows path.
        let copy = work.appending(path: "copy.txt")
        try "copied".write(to: copy, atomically: true, encoding: .utf8)
        #expect(try session.run(["cp", copy.path, "vm:C:/Users/hobo/copy.txt"]).status == 0)
        let back = work.appending(path: "back.txt")
        #expect(try session.run(["cp", "vm:C:/Users/hobo/copy.txt", back.path]).status == 0)
        #expect(try String(contentsOf: back, encoding: .utf8) == "copied")
        #expect(try session.run(["rm", "vm:C:/Users/hobo/copy.txt"]).status == 0)
        #expect(try session.run(["rm", "vm:C:/Users/hobo/copy.txt"]).status != 0)

        // Cancelling ends the command in the guest, --gui or not.
        for gui in [false, true] {
            let tag = gui ? 7001 : 7000
            let process = try session.start(["exec", "vm"] + (gui ? ["--gui"] : []) + ["--", "powershell.exe", "-Command", "Start-Sleep \(tag)"])
            Thread.sleep(forTimeInterval: 15)
            process.interrupt()
            process.waitUntilExit()
            Thread.sleep(forTimeInterval: 15)
            let left = #"@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Start-Sleep \#(tag)' -and $_.CommandLine -notmatch 'CimInstance' }).Count"#
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

    /// `[windows] resizable_display`: the patched viogpudo, test signing, a 1920×1200 desktop, and one
    /// that follows the window. Whether the window shows it intact can only be seen from the host, by eye.
    @Test(.timeLimit(.minutes(30)))
    func resizableDisplay() throws {
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let iso = try #require(environment["HOBO_WINDOWS_ISO"])
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let session = Session(hobo: hobo, directory: work, vms: work.appending(path: "vms"))
        defer { _ = try? session.run(["stop", "--force", "vm"]) }

        #expect(try session.run(["init", "--os", "windows", iso]).status == 0)
        let recipe = work.appending(path: "Hobo.toml")
        let resizable = try String(contentsOf: recipe, encoding: .utf8)
            .replacingOccurrences(of: "# [windows]\n# resizable_display = true", with: "[windows]\nresizable_display = true")
        #expect(resizable.contains("\n[windows]\n"), "the template offers it")
        try resizable.write(to: recipe, atomically: true, encoding: .utf8)
        try #require(try session.run(["create", "vm"]).status == 0)
        #expect(try VMConfig.load(from: work.appending(path: "vms/vm.hobovm/config.json")).resizableDisplay)

        try #require(try session.run(["start", "vm"]).status == 0)
        func powerShell(_ line: String) throws -> String {
            try session.run(["exec", "vm", "--", "powershell.exe", "-NoProfile", "-Command", line]).text
        }
        #expect(try powerShell("bcdedit /enum '{current}' | Select-String testsigning").contains("Yes"))
        let device = try powerShell("$v = Get-CimInstance Win32_VideoController; $v.Status + ' ' + $v.DriverVersion")
        #expect(device.contains("OK"), "the test-signed driver loaded: \(device)")
        #expect(!device.contains("30200"), "not virtio-win's 0.1.302 build: \(device)")

        let shot = work.appending(path: "shot.png")
        func desktopSize() throws -> (width: Int, height: Int) {
            #expect(try session.run(["screenshot", "vm", "--output", shot.path]).status == 0)
            let png = try Data(contentsOf: shot)
            let field = { (offset: Int) in png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
            return (field(16), field(20))
        }
        let configured = try desktopSize()
        #expect(configured == (1920, 1200))

        // The desktop follows the window, which is sized in points and keeps the display's shape.
        #expect(try session.run(["view", "vm"]).status == 0)
        var followed = configured
        for _ in 0..<15 where followed == configured {
            Thread.sleep(forTimeInterval: 2)
            followed = try desktopSize()
        }
        #expect(followed != configured, "the desktop stayed at the display's configured size")
        let aspect = { (size: (width: Int, height: Int)) in Double(size.width) / Double(size.height) }
        #expect(abs(aspect(followed) - aspect(configured)) < 0.01, "\(followed)")
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
