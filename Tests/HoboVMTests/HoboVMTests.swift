import Foundation
import HoboControl
import HoboCore
import Testing

/// Integration tests drive the signed `hobo` binary and only run with HOBO_INTEGRATION=1
/// (`make integration-test`). The test runner can't carry the virtualization entitlement, so VM
/// tests must go through the binary named by HOBO_BIN.
let environment = ProcessInfo.processInfo.environment
let integrationEnabled = environment["HOBO_INTEGRATION"] == "1"

@Suite(.enabled(if: integrationEnabled), .serialized) struct HoboVMIntegrationTests {
    /// `hobo init` writes a recipe that `hobo validate` accepts.
    @Test func initWritesAValidRecipe() throws {
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-init-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        #expect(try run(hobo, ["init"], in: work) == 0)
        #expect(FileManager.default.fileExists(atPath: work.appending(path: "Hobo.toml").path))
        #expect(try run(hobo, ["init"], in: work) != 0, "init must not overwrite without --force")
        #expect(try run(hobo, ["validate"], in: work) == 0)
    }

    /// Creates a VM from the latest IPSW, runs it through start and stop under launchd, then
    /// renames and deletes it. The recipe's step asserts the Vagrant conventions and a GUI session
    /// from inside the guest, so a VM that builds has them. It enables `[gui_testing]`, whose grants
    /// create checks and the test checks again on a later boot. VMs go to a temp `HOBO_VMS`, whose
    /// store hash keeps their launchd jobs apart from real ones; the IPSW goes through the real image
    /// index, so it downloads only once.
    @Test(.timeLimit(.minutes(150)))
    func lifecycle() throws {
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-create-\(UUID().uuidString)")
        let vms = work.appending(path: "vms")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let env = ["HOBO_VMS": vms.path]

        let recipe = work.appending(path: "Hobo.toml")
        try """
        disk = "64GB"

        [source]
        ipsw = "latest"

        [[provision]]
        type = "shell"
        privileged = false
        inline = '''
        set -eu
        sudo -n true
        grep -q 'vagrant insecure public key' ~/.ssh/authorized_keys
        test "$(pmset -g | awk '$1 == "sleep" { print $2 }')" = 0
        launchctl print gui/$(id -u) >/dev/null
        '''

        [gui_testing]
        enabled = true
        """.write(to: recipe, atomically: true, encoding: .utf8)

        try #require(try run(hobo, ["create", "itest", recipe.path], in: work, environment: env) == 0)

        let config = try VMConfig.load(from: vms.appending(path: "itest.hobovm/config.json"))
        #expect(config.engine == .vz && config.os == .macOS)
        #expect(config.guestOSVersion.hasPrefix("27."))
        #expect(config.disk == 64 << 30)
        #expect(!config.macAddress.isEmpty)
        let list = try output(hobo, ["list"], environment: env)
        #expect(list.contains(/itest\s+stopped\s+macOS 27\./))

        // Never leak a running VM: only 2 macOS guests fit on a host.
        defer { _ = try? run(hobo, ["stop", "--force", "itest"], in: work, environment: env) }
        let started = try output(hobo, ["start", "itest"], environment: env)
        #expect(started.contains(/itest is running \(\d+\.\d+\.\d+\.\d+\)/), "\(started)")
        #expect(try output(hobo, ["list"], environment: env).contains(/itest\s+running/))

        // The guest channel: ip, exec (output and exit status), ssh, and cp both ways.
        let ip = try output(hobo, ["ip", "itest"], environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(started.contains("(\(ip))"))
        #expect(try output(hobo, ["exec", "itest", "--", "sw_vers", "-productVersion"], environment: env).hasPrefix("27."))
        #expect(try run(hobo, ["exec", "itest", "--", "sh", "-c", "exit 7"], in: work, environment: env) == 7)
        #expect(try run(hobo, ["exec", "itest", "--", "zsh", "-c", GUITestingGrants.checkCommand], in: work, environment: env) == 0)
        #expect(try output(hobo, ["ssh", "itest", "--", "whoami"], environment: env) == "vagrant\n")
        let payload = work.appending(path: "payload.txt")
        try "over and back\n".write(to: payload, atomically: true, encoding: .utf8)
        #expect(try run(hobo, ["cp", payload.path, "itest:/tmp/payload.txt"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["cp", "itest:/tmp/payload.txt", "back.txt"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: work.appending(path: "back.txt"), encoding: .utf8) == "over and back\n")
        #expect(try run(hobo, ["rename", "itest", "itest2"], in: work, environment: env) != 0, "running")
        #expect(try run(hobo, ["delete", "itest", "--yes"], in: work, environment: env) != 0, "running")
        #expect(try output(hobo, ["start", "itest"], environment: env).contains("already running"))

        // The window opens on demand, while the VM keeps running. It briefly appears on screen.
        let socket = VMStore(directory: vms).job(for: "itest").socket
        func windowShown() throws -> Bool? {
            guard case .status(let status) = try ControlClient.send(.status, to: socket) else { return nil }
            return status.windowShown
        }
        #expect(try windowShown() == false)
        #expect(try run(hobo, ["view", "itest"], in: work, environment: env) == 0)
        #expect(try windowShown() == true)
        #expect(try output(hobo, ["list"], environment: env).contains(/itest\s+running \(window\)/))

        #expect(try output(hobo, ["stop", "itest"], environment: env).contains("Stopped itest"))
        #expect(try output(hobo, ["list"], environment: env).contains(/itest\s+stopped/))
        #expect(try output(hobo, ["stop", "itest"], environment: env).contains("not running"))
        #expect(try run(hobo, ["view", "itest"], in: work, environment: env) != 0, "not running")

        #expect(try run(hobo, ["start", "itest"], in: work, environment: env) == 0)
        #expect(try output(hobo, ["stop", "--force", "itest"], environment: env).contains("Stopped itest"))
        #expect(try output(hobo, ["list"], environment: env).contains(/itest\s+stopped/))

        #expect(try run(hobo, ["rename", "itest", "itest2"], in: work, environment: env) == 0)
        #expect(try output(hobo, ["list"], environment: env).contains("itest2"))
        #expect(try run(hobo, ["delete", "itest2"], in: work, environment: env) != 0, "no terminal and no --yes")
        #expect(try run(hobo, ["delete", "itest2", "--yes"], in: work, environment: env) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: vms.path).isEmpty)
    }

    /// Creates an Ubuntu VM from the recipe `init --os linux` pins (the newest LTS) and runs it
    /// through start, the guest channel, the window and stop, then deletes it. The recipe's step
    /// asserts the conventions cloud-init applied, from inside the guest.
    @Test(.timeLimit(.minutes(30)))
    func linuxLifecycle() throws {
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-linux-\(UUID().uuidString)")
        let vms = work.appending(path: "vms")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let env = ["HOBO_VMS": vms.path]

        #expect(try run(hobo, ["init", "--os", "linux"], in: work) == 0)
        let recipe = work.appending(path: "Hobo.toml")
        let pinned = try String(contentsOf: recipe, encoding: .utf8)
        try (pinned + """

        [[provision]]
        type = "shell"
        privileged = false
        inline = '''
        set -eu
        sudo -n true
        grep -q 'vagrant insecure public key' ~/.ssh/authorized_keys
        test "$(hostname)" = litest
        '''
        """).write(to: recipe, atomically: true, encoding: .utf8)
        #expect(try output(hobo, ["validate", recipe.path], environment: env).contains("Linux"))

        try #require(try run(hobo, ["create", "litest", recipe.path], in: work, environment: env) == 0)
        let bundle = vms.appending(path: "litest.hobovm")
        let config = try VMConfig.load(from: bundle.appending(path: "config.json"))
        #expect(config.engine == .vz && config.os == .linux)
        #expect(config.guestOSVersion.hasPrefix("Ubuntu "))
        #expect(config.disk == 32 << 30 && config.memory == 4 << 30)
        #expect(!FileManager.default.fileExists(atPath: bundle.appending(path: "cidata.iso").path), "the seed is only for create")
        #expect(try output(hobo, ["list"], environment: env).contains(/litest\s+stopped\s+Ubuntu\s/))

        defer { _ = try? run(hobo, ["stop", "--force", "litest"], in: work, environment: env) }
        let started = try output(hobo, ["start", "litest"], environment: env)
        #expect(started.contains(/litest is running \(\d+\.\d+\.\d+\.\d+\)/), "\(started)")
        let ip = try output(hobo, ["ip", "litest"], environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(started.contains("(\(ip))"))
        #expect(try output(hobo, ["exec", "litest", "--", "uname", "-m"], environment: env) == "aarch64\n")
        #expect(try output(hobo, ["ssh", "litest", "--", "whoami"], environment: env) == "vagrant\n")
        // Cloud-init ran once, at create, and stays off.
        #expect(try run(hobo, ["exec", "litest", "--", "test", "-e", "/etc/cloud/cloud-init.disabled"], in: work, environment: env) == 0)
        // The root filesystem grew to the recipe's disk.
        let rootBytes = try output(hobo, ["exec", "litest", "--", "df", "--output=size", "-B1", "/"], environment: env)
        let rootSize = rootBytes.split(separator: "\n").last.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        #expect((rootSize ?? 0) > 28 << 30, "\(rootBytes)")
        let payload = work.appending(path: "payload.txt")
        try "over and back\n".write(to: payload, atomically: true, encoding: .utf8)
        #expect(try run(hobo, ["cp", payload.path, "litest:/var/tmp/payload.txt"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["cp", "litest:/var/tmp/payload.txt", "back.txt"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: work.appending(path: "back.txt"), encoding: .utf8) == "over and back\n")
        #expect(try run(hobo, ["view", "litest"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: bundle.appending(path: "console.log"), encoding: .utf8).contains("litest login:"))

        #expect(try output(hobo, ["stop", "litest"], environment: env).contains("Stopped litest"))
        #expect(try run(hobo, ["delete", "litest", "--yes"], in: work, environment: env) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: vms.path).isEmpty)
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL, environment extra: [String: String] = [:]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment.merging(extra) { $1 }
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func output(_ executable: String, _ arguments: [String], environment extra: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment.merging(extra) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
