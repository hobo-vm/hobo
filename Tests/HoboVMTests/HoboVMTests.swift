import Foundation
import HoboControl
import HoboCore
import HoboUICore
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

    /// Creates a VM from the latest IPSW, runs it through start and stop under launchd, changes
    /// its hardware and shares with set, shares a folder for one run, re-runs steps with provision,
    /// then renames and deletes it. The recipe's step asserts the guest conventions and a GUI
    /// session from inside the guest, so a VM that builds has them. It enables `[gui_testing]`, whose grants
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
        grep -q 'hobo insecure public key' ~/.ssh/authorized_keys
        test "$(pmset -g | awk '$1 == "sleep" { print $2 }')" = 0
        launchctl print gui/$(id -u) >/dev/null
        '''

        [gui_testing]
        enabled = true
        """.write(to: recipe, atomically: true, encoding: .utf8)

        try #require(try run(hobo, ["create", "itest", recipe.path], in: work, environment: env) == 0)

        let config = try VMConfig.load(from: vms.appending(path: "itest.hobovm/config.json"))
        #expect(config.os == .macOS)
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
        #expect(try output(hobo, ["ssh", "itest", "--", "whoami"], environment: env) == "hobo\n")
        // Both run in hobo's launchd bootstrap, the desktop's once it is logged in, which --gui waits for.
        #expect(try output(hobo, ["exec", "itest", "--", "launchctl", "managername"], environment: env) == "Aqua\n")
        #expect(try output(hobo, ["exec", "itest", "--gui", "--", "launchctl", "managername"], environment: env) == "Aqua\n")
        #expect(try output(hobo, ["exec", "itest", "--gui", "--", "whoami"], environment: env) == "hobo\n")
        #expect(try run(hobo, ["exec", "itest", "--gui", "--", "sh", "-c", "exit 7"], in: work, environment: env) == 7)
        // A screenshot is a real PNG of the headless display, and leaves nothing behind in the guest.
        #expect(try run(hobo, ["exec", "itest", "--gui", "--", "open", "-a", "TextEdit"], in: work, environment: env) == 0)
        let shot = work.appending(path: "shot.png")
        #expect(try output(hobo, ["screenshot", "itest", "-o", shot.path], environment: env) == shot.standardizedFileURL.path + "\n")
        #expect(try output("/usr/bin/sips", ["-g", "pixelWidth", shot.path], environment: env).contains("pixelWidth: 1920"))
        #expect(try run(hobo, ["screenshot", "itest"], in: work, environment: env) == 0)
        let saved = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix("itest-") && $0.hasSuffix(".png") }
        #expect(saved.count == 1, "\(saved)")
        #expect(try output(hobo, ["exec", "itest", "--", "sh", "-c", "ls /tmp | grep -c hobo-screenshot || true"], environment: env) == "0\n")
        // Create seeded the approval, so those captures raised no dialog. replayd logs its decision at
        // the capture; finding the check it ran means this isn't passing on a log that says nothing.
        let replayd = try output(hobo, ["exec", "itest", "--", "/usr/bin/log", "show", "--last", "10m", "--predicate", #"process == "replayd""#, "--style", "compact"], environment: env)
        #expect(replayd.contains("requireAlertWithCanonicalBundleID"), "replayd's log has changed wording")
        try checkUI("itest", hobo: hobo, work: work, env: env)
        try checkApp("itest", hobo: hobo, work: work, env: env)
        #expect(!replayd.contains("userAcknowledgementAlert"), "the approval dialog was raised")
        let payload = work.appending(path: "payload.txt")
        try "over and back\n".write(to: payload, atomically: true, encoding: .utf8)
        #expect(try run(hobo, ["cp", payload.path, "itest:/tmp/payload.txt"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["cp", "itest:/tmp/payload.txt", "back.txt"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: work.appending(path: "back.txt"), encoding: .utf8) == "over and back\n")
        try checkAgent("itest", hobo: hobo, work: work, env: env, nicDown: ["sudo", "-n", "ifconfig", "en0", "down"], nicUp: ["sudo", "-n", "ifconfig", "en0", "up"])
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

        // suspend and resume: the guest carries on where it was (a process started before is still
        // there) and the saved state goes; --cold discards it and boots afresh. Not kern.boottime:
        // macOS derives it from the wall clock, which moves when resume sets it.
        let sleeper = try output(hobo, ["exec", "itest", "--", "sh", "-c", "nohup sleep 86400 >/dev/null 2>&1 & echo $!"], environment: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func sleeperAlive() throws -> Bool {
            try run(hobo, ["exec", "itest", "--", "sh", "-c", "ps -p \(sleeper) -o comm= | grep -qx sleep"], in: work, environment: env) == 0
        }
        #expect(try sleeperAlive())
        let savedState = vms.appending(path: "itest.hobovm/suspended")
        #expect(try output(hobo, ["suspend", "itest"], environment: env).contains("Suspended itest"))
        #expect(try output(hobo, ["list"], environment: env).contains(/itest\s+suspended \(\d/))
        #expect(FileManager.default.fileExists(atPath: savedState.path))
        #expect(try run(hobo, ["stop", "itest"], in: work, environment: env) != 0, "suspended")
        #expect(try run(hobo, ["set", "itest", "--cpus", "4"], in: work, environment: env) != 0, "suspended")
        let resumed = try output(hobo, ["start", "itest"], environment: env)
        #expect(resumed.contains("itest resumed"), "\(resumed)")
        #expect(!FileManager.default.fileExists(atPath: savedState.path))
        #expect(try sleeperAlive())
        // The clock was set on resume.
        try checkGuestClock("itest", hobo: hobo, env: env)
        #expect(try output(hobo, ["suspend", "itest"], environment: env).contains("Suspended itest"))
        #expect(try output(hobo, ["start", "--cold", "itest"], environment: env).contains("itest is running"))
        #expect(!FileManager.default.fileExists(atPath: savedState.path))
        #expect(try !sleeperAlive())

        try checkSnapshots(vm: "itest", dropCaches: "sudo purge", hobo: hobo, work: work, env: env)

        #expect(try output(hobo, ["stop", "itest"], environment: env).contains("Stopped itest"))
        #expect(try output(hobo, ["list"], environment: env).contains(/itest\s+stopped/))
        #expect(try output(hobo, ["stop", "itest"], environment: env).contains("not running"))
        #expect(try run(hobo, ["view", "itest"], in: work, environment: env) != 0, "not running")

        // set: CPUs, memory and a larger disk, whose APFS container the guest grows into at the next start.
        let configFile = vms.appending(path: "itest.hobovm/config.json")
        #expect(try run(hobo, ["set", "itest", "--cpus", "5", "--memory", "6GB", "--disk", "72GB"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["set", "itest", "--disk", "60GB"], in: work, environment: env) != 0, "the disk only grows")
        let updated = try VMConfig.load(from: configFile)
        #expect(updated.cpus == 5 && updated.memory == 6 << 30 && updated.disk == 72 << 30 && updated.diskGrowPending)

        // Shares: a persistent read-only one (set) and a writable one for this run only (start --share).
        let kept = work.appending(path: "kept")
        let scratch = work.appending(path: "scratch")
        for folder in [kept, scratch] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "kept\n".write(to: kept.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        #expect(try run(hobo, ["set", "itest", "--share", "\(kept.path):ro"], in: work, environment: env) == 0)
        #expect(try VMConfig.load(from: configFile).shares == [VMShare(name: "kept", path: kept.path, readOnly: true)])
        #expect(try run(hobo, ["set", "itest", "--share", kept.path], in: work, environment: env) != 0, "already shared")
        #expect(try run(hobo, ["start", "itest", "--share", kept.path], in: work, environment: env) != 0, "name collision")

        #expect(try run(hobo, ["start", "itest", "--share", scratch.path], in: work, environment: env) == 0)
        #expect(try run(hobo, ["set", "itest", "--cpus", "4"], in: work, environment: env) != 0, "running")
        #expect(try run(hobo, ["start", "itest", "--share", scratch.path], in: work, environment: env) != 0, "shares need a stopped VM")
        let shared = "/Volumes/My Shared Files"
        #expect(try output(hobo, ["exec", "itest", "--", "cat", "\(shared)/kept/hello.txt"], environment: env) == "kept\n")
        #expect(try run(hobo, ["exec", "itest", "--", "touch", "\(shared)/kept/new"], in: work, environment: env) != 0, "read-only")
        #expect(try run(hobo, ["exec", "itest", "--", "sh", "-c", "echo out > '\(shared)/scratch/from-guest'"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: scratch.appending(path: "from-guest"), encoding: .utf8) == "out\n")
        #expect(try !VMConfig.load(from: configFile).diskGrowPending)
        #expect(try output(hobo, ["exec", "itest", "--", "sysctl", "-n", "hw.ncpu"], environment: env) == "5\n")

        // A resumed run keeps its run-only share: the saved state fits only the shares it had.
        #expect(try output(hobo, ["suspend", "itest"], environment: env).contains("Suspended itest"))
        #expect(try run(hobo, ["start", "itest", "--share", kept.path], in: work, environment: env) != 0, "shares need --cold")
        #expect(try output(hobo, ["start", "itest"], environment: env).contains("itest resumed"))
        #expect(try String(contentsOf: scratch.appending(path: "from-guest"), encoding: .utf8) == "out\n")
        #expect(try output(hobo, ["exec", "itest", "--", "cat", "\(shared)/scratch/from-guest"], environment: env) == "out\n")
        #expect(try output(hobo, ["exec", "itest", "--", "cat", "\(shared)/kept/hello.txt"], environment: env) == "kept\n")
        // df reports the main container's size for /. Larger than the whole original 64 GB disk means it
        // grew (the Recovery container keeps about 5 GB of the 72).
        let rootKB = try output(hobo, ["exec", "itest", "--", "sh", "-c", "df -k / | awk 'NR == 2 { print $2 }'"], environment: env)
        #expect(UInt64(rootKB.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 64 << 20, "\(rootKB)")

        // provision: another recipe's steps, run on the running VM.
        let again = work.appending(path: "Again.toml")
        try """
        [source]
        ipsw = "latest"

        [[provision]]
        type = "file"
        source = "payload.txt"
        destination = "/tmp/provisioned.txt"

        [[provision]]
        type = "shell"
        inline = "cp /tmp/provisioned.txt /var/root/provisioned.txt"
        """.write(to: again, atomically: true, encoding: .utf8)
        #expect(try output(hobo, ["provision", "itest", again.path], environment: env).contains("Provisioned itest (2 steps)"))
        #expect(try output(hobo, ["exec", "itest", "--", "sudo", "-n", "cat", "/var/root/provisioned.txt"], environment: env)
            == "over and back\n")

        #expect(try output(hobo, ["stop", "--force", "itest"], environment: env).contains("Stopped itest"))
        #expect(try run(hobo, ["provision", "itest", again.path], in: work, environment: env) != 0, "not running")

        // The run-only share is gone after a restart; the persistent one can be removed. A persistent
        // share whose folder has gone is left out of the run, not fatal, and stays in config.json.
        #expect(try run(hobo, ["set", "itest", "--unshare", "kept"], in: work, environment: env) == 0)
        #expect(try VMConfig.load(from: configFile).shares.isEmpty)
        let gone = work.appending(path: "gone")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        #expect(try run(hobo, ["set", "itest", "--share", gone.path], in: work, environment: env) == 0)
        try FileManager.default.removeItem(at: gone)
        #expect(try run(hobo, ["start", "itest"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["exec", "itest", "--", "test", "-e", "\(shared)/scratch"], in: work, environment: env) != 0)
        #expect(try VMConfig.load(from: configFile).shares == [VMShare(name: "gone", path: gone.path, readOnly: false)])
        // discard leaves a suspended VM stopped.
        #expect(try output(hobo, ["suspend", "itest"], environment: env).contains("Suspended itest"))
        #expect(try output(hobo, ["discard", "itest"], environment: env).contains("Discarded itest's saved state"))
        #expect(!FileManager.default.fileExists(atPath: savedState.path))
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

        // --server: installing the desktop takes many minutes.
        #expect(try run(hobo, ["init", "--os", "linux", "--server"], in: work) == 0)
        let recipe = work.appending(path: "Hobo.toml")
        let pinned = try String(contentsOf: recipe, encoding: .utf8)
        try (pinned + """

        [[provision]]
        type = "shell"
        privileged = false
        inline = '''
        set -eu
        sudo -n true
        grep -q 'hobo insecure public key' ~/.ssh/authorized_keys
        test "$(hostname)" = litest
        '''
        """).write(to: recipe, atomically: true, encoding: .utf8)
        #expect(try output(hobo, ["validate", recipe.path], environment: env).contains("Linux"))

        try #require(try run(hobo, ["create", "litest", recipe.path], in: work, environment: env) == 0)
        let bundle = vms.appending(path: "litest.hobovm")
        let config = try VMConfig.load(from: bundle.appending(path: "config.json"))
        #expect(config.os == .linux)
        #expect(config.guestOSVersion.hasPrefix("Ubuntu "))
        #expect(config.disk == 32 << 30 && config.memory == 4 << 30)
        #expect(!FileManager.default.fileExists(atPath: bundle.appending(path: "cidata.iso").path), "the seed is only for create")
        #expect(try output(hobo, ["list"], environment: env).contains(/litest\s+stopped\s+Ubuntu\s/))

        // Shares: a persistent read-only one (set) and a writable one for this run only (start --share).
        let kept = work.appending(path: "kept")
        let scratch = work.appending(path: "scratch")
        for folder in [kept, scratch] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "kept\n".write(to: kept.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        #expect(try run(hobo, ["set", "litest", "--share", "\(kept.path):ro"], in: work, environment: env) == 0)

        defer { _ = try? run(hobo, ["stop", "--force", "litest"], in: work, environment: env) }
        let started = try output(hobo, ["start", "litest", "--share", scratch.path], environment: env)
        #expect(started.contains(/litest is running \(\d+\.\d+\.\d+\.\d+\)/), "\(started)")
        let ip = try output(hobo, ["ip", "litest"], environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(started.contains("(\(ip))"))
        #expect(try output(hobo, ["exec", "litest", "--", "uname", "-m"], environment: env) == "aarch64\n")
        #expect(try output(hobo, ["ssh", "litest", "--", "whoami"], environment: env) == "hobo\n")
        // --server left the desktop out, so --gui fails at once rather than waiting for one.
        let noDesktop = Date.now
        #expect(try run(hobo, ["exec", "litest", "--gui", "--", "true"], in: work, environment: env) == 125)
        #expect(try run(hobo, ["screenshot", "litest"], in: work, environment: env) != 0)
        #expect(Date.now.timeIntervalSince(noDesktop) < 30)
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
        try checkAgent(
            "litest", hobo: hobo, work: work, env: env,
            nicDown: ["sudo", "-n", "ip", "link", "set", "enp0s1", "down"], nicUp: ["sudo", "-n", "ip", "link", "set", "enp0s1", "up"]
        )
        #expect(try run(hobo, ["view", "litest"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: bundle.appending(path: "console.log"), encoding: .utf8).contains("litest login:"))

        // hobo has the host user's uid, so shared files are its own, and what it writes is the host user's.
        let shared = CloudInit.shareMountPoint
        #expect(try output(hobo, ["exec", "litest", "--", "cat", "\(shared)/kept/hello.txt"], environment: env) == "kept\n")
        #expect(try output(hobo, ["exec", "litest", "--", "stat", "-c", "%U", "\(shared)/kept/hello.txt"], environment: env) == "hobo\n")
        #expect(try run(hobo, ["exec", "litest", "--", "touch", "\(shared)/kept/new"], in: work, environment: env) != 0, "read-only")
        #expect(try run(hobo, ["exec", "litest", "--", "sh", "-c", "echo out > \(shared)/scratch/from-guest"], in: work, environment: env) == 0)
        let fromGuest = scratch.appending(path: "from-guest")
        #expect(try String(contentsOf: fromGuest, encoding: .utf8) == "out\n")
        let owner = try FileManager.default.attributesOfItem(atPath: fromGuest.path)[.ownerAccountID] as? NSNumber
        #expect(owner?.uint32Value == getuid())

        // suspend and resume: the clock is set with Linux's own command (it would be behind by at
        // least the 10 s suspended, against 5 s allowed), and the shares keep working with no
        // remount, both ways.
        #expect(try output(hobo, ["suspend", "litest"], environment: env).contains("Suspended litest"))
        try "added\n".write(to: scratch.appending(path: "while-suspended"), atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 10)
        let resumed = try output(hobo, ["start", "litest"], environment: env)
        #expect(resumed.contains("litest resumed"), "\(resumed)")
        try checkGuestClock("litest", hobo: hobo, env: env)
        #expect(try output(hobo, ["exec", "litest", "--", "cat", "\(shared)/scratch/while-suspended"], environment: env) == "added\n")
        #expect(try output(hobo, ["exec", "litest", "--", "cat", "\(shared)/kept/hello.txt"], environment: env) == "kept\n")
        #expect(try run(hobo, ["exec", "litest", "--", "sh", "-c", "echo again > \(shared)/scratch/after-resume"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: scratch.appending(path: "after-resume"), encoding: .utf8) == "again\n")

        try checkSnapshots(
            vm: "litest", dropCaches: "sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'", hobo: hobo, work: work, env: env
        )

        #expect(try output(hobo, ["stop", "litest"], environment: env).contains("Stopped litest"))
        // With no shares the device is still attached, so /mnt/hobo is an empty mount, not the disk.
        // The disk grows too: at the next start the root filesystem outgrows the whole original 32 GB
        // disk, and the pending flag clears.
        #expect(try run(hobo, ["set", "litest", "--unshare", "kept", "--disk", "40GB"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["start", "litest"], in: work, environment: env) == 0)
        let grownBytes = try output(hobo, ["exec", "litest", "--", "df", "--output=size", "-B1", "/"], environment: env)
        let grownSize = grownBytes.split(separator: "\n").last.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        #expect((grownSize ?? 0) > 36 << 30, "\(grownBytes)")
        #expect(try VMConfig.load(from: bundle.appending(path: "config.json")).diskGrowPending == false)
        #expect(try output(hobo, ["exec", "litest", "--", "findmnt", "-n", "-o", "FSTYPE", shared], environment: env) == "virtiofs\n")
        #expect(try output(hobo, ["exec", "litest", "--", "ls", "-A", shared], environment: env) == "")

        // clone: the source must be stopped; the clone gets its own MAC and identifier, so both
        // run at once, each with its own lease (netplan matches the NIC by driver, not MAC).
        #expect(try run(hobo, ["clone", "litest", "lclone"], in: work, environment: env) != 0, "running")
        #expect(try output(hobo, ["stop", "litest"], environment: env).contains("Stopped litest"))
        #expect(try output(hobo, ["clone", "litest", "lclone"], environment: env).contains("Cloned litest to lclone"))
        let cloneConfig = try VMConfig.load(from: vms.appending(path: "lclone.hobovm/config.json"))
        #expect(cloneConfig.macAddress != config.macAddress && !cloneConfig.ephemeral)
        let identifier = "machine-identifier.bin"
        #expect(try Data(contentsOf: bundle.appending(path: identifier)) != Data(contentsOf: vms.appending(path: "lclone.hobovm/\(identifier)")))
        defer { _ = try? run(hobo, ["stop", "--force", "lclone"], in: work, environment: env) }
        #expect(try run(hobo, ["start", "litest"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["start", "lclone"], in: work, environment: env) == 0)
        let cloneIP = try output(hobo, ["ip", "lclone"], environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIP = try output(hobo, ["ip", "litest"], environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!cloneIP.isEmpty && cloneIP != sourceIP)
        #expect(try output(hobo, ["exec", "lclone", "--", "whoami"], environment: env) == "hobo\n")
        #expect(try output(hobo, ["exec", "litest", "--", "whoami"], environment: env) == "hobo\n")
        #expect(try run(hobo, ["delete", "lclone", "--yes"], in: work, environment: env) != 0, "running")
        #expect(try output(hobo, ["delete", "lclone", "--force"], environment: env).contains("Deleted lclone"))
        #expect(!FileManager.default.fileExists(atPath: vms.appending(path: "lclone.hobovm").path))

        // start --ephemeral: a new auto-named clone, deleted when it stops unless set --keep.
        #expect(try run(hobo, ["start", "litest", "--ephemeral"], in: work, environment: env) != 0, "running")
        #expect(try output(hobo, ["stop", "litest"], environment: env).contains("Stopped litest"))
        func startEphemeral() throws -> String {
            let started = try output(hobo, ["start", "litest", "--ephemeral"], environment: env)
            let name = try #require(started.firstMatch(of: /(litest-[0-9a-f]{4}) is running/)?.1, "\(started)")
            return String(name)
        }
        let ephemeral = try startEphemeral()
        defer { _ = try? run(hobo, ["stop", "--force", ephemeral], in: work, environment: env) }
        #expect(try output(hobo, ["list"], environment: env).contains(try Regex("\(ephemeral)\\s+running, ephemeral")))
        #expect(try output(hobo, ["exec", ephemeral, "--", "whoami"], environment: env) == "hobo\n")
        #expect(try output(hobo, ["stop", ephemeral], environment: env).contains("Stopped and deleted \(ephemeral)"))
        #expect(!FileManager.default.fileExists(atPath: vms.appending(path: "\(ephemeral).hobovm").path))
        #expect(!FileManager.default.fileExists(atPath: VMStore(directory: vms).job(for: ephemeral).log.path), "a clean run's log goes too")
        // A guest that shuts itself down is deleted too.
        let selfStopping = try startEphemeral()
        defer { _ = try? run(hobo, ["stop", "--force", selfStopping], in: work, environment: env) }
        _ = try run(hobo, ["exec", selfStopping, "--", "sudo", "-n", "shutdown", "-h", "now"], in: work, environment: env)
        let deadline = Date.now.addingTimeInterval(120)
        while FileManager.default.fileExists(atPath: vms.appending(path: "\(selfStopping).hobovm").path), Date.now < deadline {
            Thread.sleep(forTimeInterval: 2)
        }
        #expect(!FileManager.default.fileExists(atPath: vms.appending(path: "\(selfStopping).hobovm").path))
        let keptClone = try startEphemeral()
        defer { _ = try? run(hobo, ["stop", "--force", keptClone], in: work, environment: env) }
        #expect(try run(hobo, ["set", keptClone, "--keep"], in: work, environment: env) == 0)
        #expect(try output(hobo, ["stop", keptClone], environment: env).contains("Stopped \(keptClone)\n"))
        #expect(try output(hobo, ["list"], environment: env).contains(try Regex("\(keptClone)\\s+stopped\\s")))
        #expect(try run(hobo, ["delete", keptClone, "--yes"], in: work, environment: env) == 0)

        try checkIdleTimeout(hobo: hobo, work: work, vms: vms, env: env)

        #expect(try run(hobo, ["delete", "litest", "--yes"], in: work, environment: env) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: vms.path).isEmpty)
    }

    /// What hobo-agent (decision 15) does beyond plain exec and cp: directories copy both ways as
    /// `scp -r` would, a cancelled exec ends in the guest, `provision` runs in the VM process, and
    /// none of it needs the guest's network.
    func checkAgent(_ vm: String, hobo: String, work: URL, env: [String: String], nicDown: [String], nicUp: [String]) throws {
        let tree = work.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "sub"), withIntermediateDirectories: true)
        try "deep\n".write(to: tree.appending(path: "sub/deep.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "link").path, withDestinationPath: "sub/deep.txt")
        #expect(try run(hobo, ["cp", tree.path, "\(vm):tree"], in: work, environment: env) != 0, "a directory needs -r")
        #expect(try run(hobo, ["cp", "-r", tree.path, "\(vm):tree"], in: work, environment: env) == 0)
        #expect(try output(hobo, ["exec", vm, "--", "cat", "tree/link"], environment: env) == "deep\n")
        #expect(try run(hobo, ["cp", "-r", "\(vm):tree", "tree-back"], in: work, environment: env) == 0)
        #expect(try String(contentsOf: work.appending(path: "tree-back/sub/deep.txt"), encoding: .utf8) == "deep\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: work.appending(path: "tree-back/link").path) == "sub/deep.txt")
        #expect(try run(hobo, ["cp", "\(vm):/nonexistent", "\(vm):tree/sub/deep.txt", "missing-dir/"], in: work, environment: env) != 0)

        // ^C on the client ends the command in the guest.
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: hobo)
        sleeper.arguments = ["exec", vm, "--", "sleep", "1234"]
        sleeper.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        try sleeper.run()
        Thread.sleep(forTimeInterval: 3)
        #expect(try run(hobo, ["exec", vm, "--", "pgrep", "-f", "sleep 1234"], in: work, environment: env) == 0)
        sleeper.interrupt()
        sleeper.waitUntilExit()
        Thread.sleep(forTimeInterval: 2)
        #expect(try run(hobo, ["exec", vm, "--", "pgrep", "-f", "sleep 1234"], in: work, environment: env) != 0)

        // A recipe of its own: provision reads only its steps, but it must still be a whole recipe.
        let recipe = work.appending(path: "provision.toml")
        try (String(contentsOf: work.appending(path: "Hobo.toml"), encoding: .utf8) + """

        [[provision]]
        type = "shell"
        privileged = false
        inline = "echo provisioned as $(whoami) > ~/provisioned"
        """).write(to: recipe, atomically: true, encoding: .utf8)
        #expect(try run(hobo, ["provision", vm, recipe.path], in: work, environment: env) == 0)
        #expect(try output(hobo, ["exec", vm, "--", "cat", "provisioned"], environment: env) == "provisioned as hobo\n")

        // With its network down the guest still answers.
        #expect(try run(hobo, ["exec", vm, "--"] + nicDown, in: work, environment: env) == 0)
        #expect(try output(hobo, ["exec", vm, "--", "echo", "still here"], environment: env) == "still here\n")
        #expect(try run(hobo, ["exec", vm, "--"] + nicUp, in: work, environment: env) == 0)
    }

    /// Creates an Ubuntu VM with the desktop `init --os linux` adds by default and tests GUI work in it
    /// (decision 21): `exec --gui` in the Wayland session, an app driven over AT-SPI, and a
    /// screenshot, taken twice so the second shows no permission dialog left by the first.
    @Test(.timeLimit(.minutes(40)))
    func linuxDesktop() throws {
        let hobo = try #require(environment["HOBO_BIN"], "run via make integration-test")
        let work = FileManager.default.temporaryDirectory.appending(path: "hobo-linux-desktop-\(UUID().uuidString)")
        let vms = work.appending(path: "vms")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let env = ["HOBO_VMS": vms.path]

        #expect(try run(hobo, ["init", "--os", "linux"], in: work) == 0)
        try #require(try run(hobo, ["create", "ldesk", work.appending(path: "Hobo.toml").path], in: work, environment: env) == 0)
        defer { _ = try? run(hobo, ["stop", "--force", "ldesk"], in: work, environment: env) }
        #expect(try run(hobo, ["start", "ldesk"], in: work, environment: env) == 0)

        // Plain exec has no display; --gui waits for the session, then has the desktop's.
        #expect(try output(hobo, ["exec", "ldesk", "--", "sh", "-c", "echo ${WAYLAND_DISPLAY:-none}"], environment: env) == "none\n")
        let session = try output(hobo, ["exec", "ldesk", "--gui", "--", "sh", "-c", "echo $XDG_SESSION_TYPE $WAYLAND_DISPLAY; whoami"], environment: env)
        #expect(session == "wayland wayland-0\nhobo\n", "\(session)")
        #expect(try run(hobo, ["exec", "ldesk", "--gui", "--", "sh", "-c", "exit 7"], in: work, environment: env) == 7)
        #expect(try output(hobo, ["exec", "ldesk", "--gui", "--", "gsettings", "get", "org.gnome.desktop.interface", "toolkit-accessibility"], environment: env) == "true\n")

        // An app started with exec --gui shows up over AT-SPI, which can drive it.
        let calculator = Process()
        calculator.executableURL = URL(filePath: hobo)
        calculator.arguments = ["exec", "ldesk", "--gui", "--", "gnome-calculator"]
        calculator.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        calculator.standardOutput = FileHandle.nullDevice
        calculator.standardError = FileHandle.nullDevice
        try calculator.run()
        defer { if calculator.isRunning { calculator.terminate() } }
        let driven = try output(hobo, ["exec", "ldesk", "--gui", "--", "python3", "-c", """
            import time, gi
            gi.require_version("Atspi", "2.0")
            from gi.repository import Atspi
            def find(node, test):
                if test(node): return node
                for i in range(node.get_child_count()):
                    found = find(node.get_child_at_index(i), test)
                    if found: return found
            app = None
            for _ in range(30):
                app = find(Atspi.get_desktop(0), lambda n: n.get_role_name() == "application" and n.get_name() == "gnome-calculator")
                if app: break
                time.sleep(1)
            Atspi.Action.do_action(find(app, lambda n: n.get_role_name() == "button" and n.get_name() == "7"), 0)
            time.sleep(1)
            print(Atspi.Text.get_text(find(app, lambda n: n.get_role_name() == "text"), 0, -1))
            """], environment: env)
        #expect(driven == "7\n", "\(driven)")

        // The screenshot is the whole 1920x1200 display, twice, and leaves nothing in ~/Pictures.
        for attempt in 1...2 {
            let shot = work.appending(path: "shot\(attempt).png")
            #expect(try output(hobo, ["screenshot", "ldesk", "-o", shot.path], environment: env) == shot.standardizedFileURL.path + "\n")
            let size = try output("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", shot.path], environment: env)
            #expect(size.contains("pixelWidth: 1920") && size.contains("pixelHeight: 1200"), "\(size)")
        }
        #expect(try output(hobo, ["exec", "ldesk", "--", "sh", "-c", "ls ~/Pictures | wc -l"], environment: env) == "0\n")

        // Cancelling exec --gui (the client going away) ends the app too.
        calculator.terminate()
        calculator.waitUntilExit()
        #expect(try run(hobo, ["exec", "ldesk", "--", "sh", "-c", "sleep 2; ! pgrep -f [g]nome-calculator"], in: work, environment: env) == 0)

        #expect(try output(hobo, ["stop", "ldesk"], environment: env).contains("Stopped ldesk"))
        #expect(try run(hobo, ["delete", "ldesk", "--yes"], in: work, environment: env) == 0)
    }

    /// Decision 18 on a real clone of the stopped VM `litest`: a renewal restarts the timeout, a request
    /// outlasting it holds it, `list` shows the countdown without renewing it, and expiry stops and
    /// deletes the clone. `set --keep`, an unreadable `config.json` and `off` each spare a clone past a
    /// timeout that has passed.
    private func checkIdleTimeout(hobo: String, work: URL, vms: URL, env: [String: String]) throws {
        func start(_ timeout: String) throws -> (name: String, text: String) {
            let started = try output(hobo, ["start", "litest", "--ephemeral", "--idle-timeout", timeout], environment: env)
            let name = try #require(started.firstMatch(of: /(litest-[0-9a-f]{4}) is running/)?.1, "\(started)")
            return (String(name), started)
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: vms.appending(path: "\(name).hobovm").path) }
        func list() throws -> String { try output(hobo, ["list"], environment: env) }

        #expect(try run(hobo, ["start", "litest", "--idle-timeout", "5m"], in: work, environment: env) != 0, "not ephemeral")

        let (expiring, text) = try start("20s")
        defer { _ = try? run(hobo, ["stop", "--force", expiring], in: work, environment: env) }
        #expect(text.contains("deleted after 20s idle"), "\(text)")
        #expect(try list().contains(try Regex("\(expiring)\\s+running, ephemeral, \\d+s left")))
        Thread.sleep(forTimeInterval: 3)
        let renewed = try output(hobo, ["start", expiring, "--json"], environment: env)
        #expect(renewed.contains(/"idleSecondsRemaining":\s*20\b/), "a renewal restarts the full timeout: \(renewed)")
        #expect(try output(hobo, ["exec", expiring, "--", "sh", "-c", "sleep 30; echo held"], environment: env) == "held\n")
        #expect(exists(expiring), "the exec outlasted the timeout")
        // Polling `list` doesn't keep it alive: the full stop sequence fits well inside this.
        let deadline = Date.now.addingTimeInterval(180)
        while exists(expiring), Date.now < deadline {
            _ = try? list()
            Thread.sleep(forTimeInterval: 2)
        }
        #expect(!exists(expiring), "expired and deleted")

        let (kept, _) = try start("20s")
        defer { _ = try? run(hobo, ["stop", "--force", kept], in: work, environment: env) }
        #expect(try run(hobo, ["set", kept, "--keep"], in: work, environment: env) == 0)
        Thread.sleep(forTimeInterval: 25)
        #expect(try list().contains(try Regex("\(kept)\\s+running\\s")), "kept: no timeout, and no longer ephemeral")
        #expect(try run(hobo, ["delete", kept, "--force"], in: work, environment: env) == 0)

        // An unreadable config.json can't say the clone wasn't kept, so its expiry deletes nothing.
        let (unreadable, _) = try start("20s")
        defer { _ = try? run(hobo, ["stop", "--force", unreadable], in: work, environment: env) }
        let configFile = vms.appending(path: "\(unreadable).hobovm/config.json")
        let config = try Data(contentsOf: configFile)
        try Data("not json".utf8).write(to: configFile)
        Thread.sleep(forTimeInterval: 25)
        try config.write(to: configFile)
        #expect(try list().contains(try Regex("\(unreadable)\\s+running, ephemeral, \\d+s left")), "still up, and counting again")
        #expect(try output(hobo, ["stop", unreadable], environment: env).contains("Stopped and deleted \(unreadable)"))

        let (untimed, _) = try start("off")
        defer { _ = try? run(hobo, ["stop", "--force", untimed], in: work, environment: env) }
        #expect(try list().contains(try Regex("\(untimed)\\s+running, ephemeral, no timeout")))
        #expect(try output(hobo, ["stop", untimed], environment: env).contains("Stopped and deleted \(untimed)"))
    }

    /// The guest's clock reads the host's time, within 5 s. The host is read both sides of the
    /// `exec`, so a slow command isn't taken for a clock that's behind.
    private func checkGuestClock(_ vm: String, hobo: String, env: [String: String]) throws {
        let before = Date.now.timeIntervalSince1970
        let text = try output(hobo, ["exec", vm, "--", "date", "+%s"], environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = Date.now.timeIntervalSince1970
        let guest = Double(text) ?? 0
        #expect(guest > before - 5 && guest < after + 5, "guest \(text), \(guest - before) s from the host before exec, which took \(after - before) s")
    }

    /// Decision 13 on a running VM, which it leaves running with no snapshots. A live snapshot's VM
    /// runs on past the save, and restoring returns to that moment: the same process, the disk as it
    /// was (read back with the guest's caches dropped, since memory alone would pass), the clock
    /// right. A stopped VM's snapshot brings back only the disk, and stays stopped.
    private func checkSnapshots(vm: String, dropCaches: String, hobo: String, work: URL, env: [String: String]) throws {
        func guest(_ script: String) throws -> String {
            try output(hobo, ["exec", vm, "--", "sh", "-c", script], environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Not synced, so it is only as safe as a disk cloned at the moment the state was saved.
        let sum = try guest("dd if=/dev/urandom of=$HOME/unsynced bs=1048576 count=20 2>/dev/null; echo before > $HOME/marker; cksum < $HOME/unsynced")
        let sleeper = try guest("nohup sleep 86400 >/dev/null 2>&1 & echo $!")
        func sleeperAlive() throws -> Bool {
            try run(hobo, ["exec", vm, "--", "sh", "-c", "ps -p \(sleeper) -o comm= | grep -qx sleep"], in: work, environment: env) == 0
        }

        let saved = try output(hobo, ["snapshot", "save", vm, "live"], environment: env)
        #expect(saved.contains("Saved snapshot live"), "\(saved)")
        #expect(try sleeperAlive())
        try checkGuestClock(vm, hobo: hobo, env: env)
        #expect(try run(hobo, ["snapshot", "save", vm, "live"], in: work, environment: env) != 0, "tag taken")
        #expect(try output(hobo, ["snapshot", "list", vm], environment: env).contains(/live\s+live/))

        _ = try guest("echo after > $HOME/marker; rm $HOME/unsynced; kill \(sleeper); sync")
        #expect(try run(hobo, ["snapshot", "restore", vm, "live"], in: work, environment: env) != 0, "running, without --force")
        #expect(try guest("cat $HOME/marker") == "after")

        let restored = try output(hobo, ["snapshot", "restore", "--force", vm, "live"], environment: env)
        #expect(restored.contains("\(vm) is running"), "\(restored)")
        #expect(try sleeperAlive())
        try checkGuestClock(vm, hobo: hobo, env: env)
        _ = try guest(dropCaches)
        #expect(try guest("cat $HOME/marker") == "before")
        #expect(try guest("cksum < $HOME/unsynced") == sum)

        // A restore opens no window of its own, but one that was showing comes back with the VM. It
        // opens just after the guest answers SSH, so it may be a moment behind the restore.
        func windowShown() throws -> Bool {
            try output(hobo, ["list"], environment: env).contains(Regex("\(vm)\\s+running \\(window\\)"))
        }
        #expect(try !windowShown())
        #expect(try run(hobo, ["view", vm], in: work, environment: env) == 0)
        #expect(try output(hobo, ["snapshot", "restore", "--force", vm, "live"], environment: env).contains("\(vm) is running"))
        let deadline = Date.now.addingTimeInterval(30)
        while try !windowShown(), Date.now < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        #expect(try windowShown())

        // Restored once, the snapshot is still there to restore again, and suspended it takes --force.
        _ = try guest("echo again > $HOME/marker; sync")
        #expect(try output(hobo, ["suspend", vm], environment: env).contains("Suspended \(vm)"))
        #expect(try output(hobo, ["snapshot", "save", vm, "suspended"], environment: env).contains("Saved snapshot suspended"))
        #expect(try output(hobo, ["list"], environment: env).contains(Regex("\(vm)\\s+suspended")))
        #expect(try run(hobo, ["snapshot", "restore", vm, "live"], in: work, environment: env) != 0, "suspended, without --force")
        #expect(try output(hobo, ["snapshot", "restore", "--force", vm, "live"], environment: env).contains("\(vm) is running"))
        #expect(try guest("cat $HOME/marker") == "before")
        #expect(try output(hobo, ["snapshot", "restore", "--force", vm, "suspended"], environment: env).contains("\(vm) is running"))
        #expect(try guest("cat $HOME/marker") == "again")

        #expect(try output(hobo, ["stop", vm], environment: env).contains("Stopped \(vm)"))
        #expect(try output(hobo, ["snapshot", "save", vm, "cold"], environment: env).contains("disk only"))
        #expect(try run(hobo, ["start", vm], in: work, environment: env) == 0)
        _ = try guest("echo later > $HOME/marker; sync")
        #expect(try output(hobo, ["stop", vm], environment: env).contains("Stopped \(vm)"))
        #expect(try output(hobo, ["snapshot", "restore", vm, "cold"], environment: env).contains("is stopped"))
        #expect(try output(hobo, ["list"], environment: env).contains(Regex("\(vm)\\s+stopped")))
        #expect(try run(hobo, ["start", vm], in: work, environment: env) == 0)
        #expect(try guest("cat $HOME/marker") == "again")

        for tag in ["live", "suspended", "cold"] {
            #expect(try run(hobo, ["snapshot", "delete", vm, tag], in: work, environment: env) == 0)
        }
        #expect(try output(hobo, ["snapshot", "list", vm], environment: env).contains("no snapshots"))
    }

    /// `hobo ui` against TextEdit (left open by the screenshot check) and Finder, whose results are
    /// checked through the apps' own state: the text area's value, a checkbox's, and a file a drag moved.
    private func checkUI(_ vm: String, hobo: String, work: URL, env: [String: String]) throws {
        func ui(_ arguments: [String]) throws -> Int32 { try run(hobo, ["ui", vm] + arguments, in: work, environment: env) }
        func snapshot(_ app: String) throws -> [SnapshotNode] { try uiSnapshot(vm, app: app, hobo: hobo, env: env) }
        let find = Self.find

        #expect(try ui(["wait", "--app", "TextEdit"]) == 0)
        let text = try #require(find(try snapshot("TextEdit")) { $0.role == "textarea" })
        #expect(try ui(["type", "Hello from hobo ui", "--into", text.ref, "--app", "TextEdit"]) == 0)
        #expect(try ui(["wait", "--text", "Hello from hobo ui", "--app", "TextEdit", "--timeout", "5"]) == 0)
        // Refs keep their numbers across snapshots.
        let typed = try #require(find(try snapshot("TextEdit")) { $0.role == "textarea" })
        #expect(typed.ref == text.ref)
        #expect(typed.value == "Hello from hobo ui")

        let bold = try #require(find(try snapshot("TextEdit")) { $0.name == "bold" })
        #expect(bold.checked == false)
        #expect(try ui(["key", "cmd+a"]) == 0)
        #expect(try ui(["click", bold.ref, "--app", "TextEdit"]) == 0)
        #expect(find(try snapshot("TextEdit")) { $0.ref == bold.ref }?.checked == true)
        #expect(try ui(["scroll", text.ref, "down", "3", "--app", "TextEdit"]) == 0)
        #expect(try ui(["menu", "Format > Font > Show Fonts", "--app", "TextEdit"]) == 0)
        #expect(try output(hobo, ["ui", vm, "menu", "Format", "--app", "TextEdit"], environment: env).contains(#""Make Plain Text" cmd+shift+t"#))
        #expect(try ui(["click", "e99999", "--app", "TextEdit"]) == 1, "an unknown ref fails")
        #expect(try ui(["wait", "--text", "never there", "--app", "TextEdit", "--timeout", "0.5"]) == 1)

        // Finder's icon view: drag a file onto a folder, and find it moved on disk.
        #expect(try run(hobo, ["exec", vm, "--", "sh", "-c", "mkdir -p ~/DragTest/Folder && touch ~/DragTest/a.txt && open ~/DragTest"], in: work, environment: env) == 0)
        #expect(try ui(["wait", "--text", "a.txt", "--app", "Finder"]) == 0)
        let finder = try snapshot("Finder")
        let file = try #require(find(finder) { $0.role == "image" && $0.name == "a.txt" })
        let folder = try #require(find(finder) { $0.role == "image" && $0.name == "Folder" })
        #expect(try ui(["drag", file.ref, folder.ref, "--app", "Finder"]) == 0)
        #expect(try ui(["wait", "--ref", file.ref, "--gone", "--app", "Finder"]) == 0)
        #expect(try run(hobo, ["exec", vm, "--", "test", "-f", "DragTest/Folder/a.txt"], in: work, environment: env) == 0)
    }

    /// Hobo.app in the guest (designs/hobo-app.md), from the bundle HOBO_BIN is in, over a store seeded
    /// with two stopped VMs: its list, a settings change and a rename, checked in the bundles, and
    /// a New VM build from the sheet. The guest can't run VMs itself, so that build is made to fail at
    /// once, by naming a VM that exists, after the sheet has written its recipe.
    private func checkApp(_ vm: String, hobo: String, work: URL, env: [String: String]) throws {
        let app = "app.gsquared.hobo"
        func ui(_ arguments: [String]) throws -> Int32 { try run(hobo, ["ui", vm] + arguments + ["--app", app], in: work, environment: env) }
        func guest(_ command: String) throws -> String { try output(hobo, ["exec", vm, "--", "sh", "-c", command], environment: env) }
        func snapshot() throws -> [SnapshotNode] { try uiSnapshot(vm, app: app, hobo: hobo, env: env) }
        func row(_ name: String) throws -> SnapshotNode {
            try #require(Self.find(try snapshot()) { $0.role == "cell" && $0.children.contains { $0.value == name } }, "no row for \(name)")
        }
        let bundle = URL(filePath: hobo).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(bundle.lastPathComponent == "Hobo.app", "HOBO_BIN must be the CLI in Hobo.app (make integration-test)")

        let config = work.appending(path: "seed-config.json")
        try VMConfig(
            os: .linux, cpus: 2, memory: 4 << 30, disk: 32 << 30, macAddress: "5a:00:00:00:00:01", guestOSVersion: "Ubuntu 26.04",
            created: .now, recipeSHA256: "a", sourceSHA256: "b"
        ).write(to: config)
        #expect(try guest("mkdir -p ~/Applications ~/Hobo/alpha.hobovm ~/Hobo/beta.hobovm") == "")
        for name in ["alpha", "beta"] {
            #expect(try run(hobo, ["cp", config.path, "\(vm):/Users/hobo/Hobo/\(name).hobovm/config.json"], in: work, environment: env) == 0)
        }
        #expect(try run(hobo, ["cp", "-r", bundle.path, "\(vm):/Users/hobo/Applications/"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["exec", vm, "--gui", "--", "open", "/Users/hobo/Applications/Hobo.app"], in: work, environment: env) == 0)
        #expect(try ui(["wait", "--text", "beta"]) == 0)

        // A settings change: the memory stepper up a step, then Save, as hobo set --memory 5GB. (Not the
        // disk, which would resize the seeded bundle's disk image, and it has none.)
        #expect(try ui(["click", try row("alpha").ref]) == 0)
        #expect(try ui(["wait", "--text", "Memory: 4 GB"]) == 0)
        var steppers = [SnapshotNode]()
        func collect(_ nodes: [SnapshotNode]) { for node in nodes { if node.role == "incrementor" { steppers.append(node) }; collect(node.children) } }
        collect(try snapshot())
        let memoryUp = try #require(steppers.count == 3 ? steppers[1].children.first : nil, "CPUs, memory and disk steppers")
        #expect(try ui(["click", memoryUp.ref, "--press"]) == 0)
        #expect(try ui(["wait", "--text", "Memory: 5 GB"]) == 0)
        let save = try #require(Self.find(try snapshot()) { $0.role == "button" && $0.name == "Save" })
        #expect(try ui(["scroll", "--to", save.ref]) == 0)
        #expect(try ui(["click", save.ref]) == 0)
        let memory = try guest("for i in $(seq 50); do grep -q 5368709120 ~/Hobo/alpha.hobovm/config.json && break; sleep 0.2; done; grep -o '\"memory\" : [0-9]*' ~/Hobo/alpha.hobovm/config.json")
        try #require(memory == "\"memory\" : 5368709120\n", "\(memory)")

        // A rename, from the row's context menu.
        #expect(try ui(["click", try row("beta").ref, "--right"]) == 0)
        let rename = try #require(Self.find(try snapshot()) { $0.role == "menuitem" && $0.name == "Rename…" })
        #expect(try ui(["click", rename.ref]) == 0)
        let field = try #require(Self.find(try snapshot()) { $0.role == "textfield" && $0.value == "beta" })
        #expect(try ui(["click", field.ref]) == 0)
        #expect(try run(hobo, ["ui", vm, "key", "cmd+a"], in: work, environment: env) == 0)
        #expect(try run(hobo, ["ui", vm, "type", "gamma"], in: work, environment: env) == 0)
        let confirm = try #require(Self.find(try snapshot()) { $0.role == "button" && $0.name == "Rename" })
        #expect(try ui(["click", confirm.ref]) == 0)
        #expect(try ui(["wait", "--text", "gamma"]) == 0)
        #expect(try guest("ls ~/Hobo") == "alpha.hobovm\ngamma.hobovm\n")

        // New VM: the sheet starts a build from the recipe it writes (whose contents NewVMFormTests
        // checks), and the build, failing, leaves no temporary recipe behind.
        #expect(try ui(["menu", "File > New VM…"]) == 0)
        #expect(try ui(["wait", "--text", "GUI testing"]) == 0)
        let sheet = try snapshot()
        let name = try #require(Self.find(sheet) { $0.role == "textfield" })
        let guiTesting = try #require(Self.find(sheet) { $0.role == "switch" })
        let create = try #require(Self.find(sheet) { $0.role == "button" && $0.name == "Create" })
        #expect(try ui(["type", "alpha", "--into", name.ref]) == 0)
        #expect(try ui(["click", guiTesting.ref]) == 0)
        #expect(try ui(["click", create.ref]) == 0)
        #expect(try ui(["wait", "--text", "already exists"]) == 0)
        #expect(try guest(#"ls -d "$(getconf DARWIN_USER_TEMP_DIR)"Hobo-* 2>/dev/null | wc -l | tr -d ' '"#) == "0\n")
        #expect(try guest("osascript -e 'quit app id \"\(app)\"'; rm -rf ~/Applications/Hobo.app ~/Hobo") == "")
    }

    private func uiSnapshot(_ vm: String, app: String, hobo: String, env: [String: String]) throws -> [SnapshotNode] {
        let json = try output(hobo, ["ui", vm, "snapshot", "--app", app, "--all", "--json"], environment: env)
        struct Reply: Decodable { var snapshot: AppSnapshot }
        return try JSONDecoder().decode(Reply.self, from: Data(json.utf8)).snapshot.elements
    }

    private static func find(_ nodes: [SnapshotNode], _ match: (SnapshotNode) -> Bool) -> SnapshotNode? {
        for node in nodes {
            if match(node) { return node }
            if let found = find(node.children, match) { return found }
        }
        return nil
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
