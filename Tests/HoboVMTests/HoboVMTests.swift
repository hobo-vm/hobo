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

    /// Creates a VM from the latest IPSW, runs it through start and stop under launchd, changes
    /// its hardware and shares with set, shares a folder for one run, re-runs steps with provision,
    /// then renames and deletes it. The recipe's step asserts the Vagrant conventions and a GUI
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
        // The clock was set on resume: within a minute of the host's.
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

        // vagrant has the host user's uid, so shared files are its own, and what it writes is the host user's.
        let shared = CloudInit.shareMountPoint
        #expect(try output(hobo, ["exec", "litest", "--", "cat", "\(shared)/kept/hello.txt"], environment: env) == "kept\n")
        #expect(try output(hobo, ["exec", "litest", "--", "stat", "-c", "%U", "\(shared)/kept/hello.txt"], environment: env) == "vagrant\n")
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
        #expect(try output(hobo, ["exec", "lclone", "--", "whoami"], environment: env) == "vagrant\n")
        #expect(try output(hobo, ["exec", "litest", "--", "whoami"], environment: env) == "vagrant\n")
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
        #expect(try output(hobo, ["exec", ephemeral, "--", "whoami"], environment: env) == "vagrant\n")
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

        #expect(try run(hobo, ["delete", "litest", "--yes"], in: work, environment: env) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: vms.path).isEmpty)
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
