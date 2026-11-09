import Foundation
import HoboCore
import Synchronization
import Virtualization

/// Creates a named VM from a recipe, built in place in its bundle. Every create is a full install.
/// A failed or interrupted (^C) create deletes the bundle.
/// - macOS: IPSW → unattended install → guest conventions and hobo-agent, over password SSH →
///   `[security]` (SIP off by hand in recoveryOS) → `[gui_testing]` grants → recipe steps, through
///   the agent → cleanup → clean shutdown.
/// - Linux: cloud image → ASIF disk → a boot with a cloud-init seed that applies the guest
///   conventions and installs hobo-agent → recipe steps, through the agent → cleanup → clean shutdown.
/// - Windows: ISO → install media, with hobo-agent → a boot that installs from it → a boot that
///   runs Windows' own setup and the guest conventions → recipe steps, through the agent →
///   cleanup → clean shutdown.
@MainActor
public struct VMCreator {
    public struct Options: Sendable {
        public var name: String
        public var recipeFile: URL
        /// On failure, leave the VM running for SSH until interrupted; the bundle is deleted after.
        public var holdOnFailure: Bool

        public init(name: String, recipeFile: URL, holdOnFailure: Bool = false) {
            self.name = name
            self.recipeFile = recipeFile
            self.holdOnFailure = holdOnFailure
        }
    }

    let store: VMStore
    let home: HoboHome
    let options: Options
    let log: @Sendable (String) -> Void
    /// Reports a ^C or SIGTERM, given what it leaves behind, just before the process exits.
    let interrupted: @Sendable (String) -> Void

    /// `interrupted` defaults to a log line; a caller whose output needs a final error (`--json`)
    /// passes its own.
    public init(
        store: VMStore = .standard(), home: HoboHome = .standard(), options: Options,
        log: @escaping @Sendable (String) -> Void, interrupted: (@Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.home = home
        self.options = options
        self.log = log
        self.interrupted = interrupted ?? { consequence in log("\nInterrupted; \(consequence)") }
    }

    public func create() async throws -> VMConfig {
        // Parsed from the bytes that are hashed and copied into the bundle, so all three agree.
        let recipeData = try Data(contentsOf: options.recipeFile)
        guard let toml = String(data: recipeData, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: options.recipeFile])
        }
        let recipe = try Recipe.parse(toml, directory: options.recipeFile.deletingLastPathComponent())
        try recipe.checkFilesExist()
        if !recipe.security.sip {
            // Checked before the long install rather than when the person is needed.
            guard SIPRecoveryStep.canShowUI else { throw VMError.needsGUISession }
            log("This recipe turns SIP off, which needs you: once macOS is installed (about 5 minutes, longer if the IPSW downloads), the VM opens in recoveryOS for you to type one command.")
        }

        let bundle = try store.beginCreate(options.name)
        let interrupts = InterruptCleanup(bundle: bundle, interrupted: interrupted)
        defer { interrupts.cancel() }
        do {
            log("Creating \(options.name) from \(options.recipeFile.path) in \(bundle.path)")
            let config = try await build(recipe, recipeSHA256: VMStore.sha256(recipeData), in: bundle)
            try store.finishCreate(options.name, config: config, recipe: recipeData)
            return config
        } catch {
            do {
                try store.abandonCreate(options.name)
                log("Deleted \(bundle.path)")
            } catch let cleanupError {
                log("warning: could not delete \(bundle.path): \(cleanupError)")
            }
            throw error
        }
    }

    private func build(_ recipe: Recipe, recipeSHA256: String, in directory: URL) async throws -> VMConfig {
        switch recipe.os {
        case .macOS: try await buildMac(recipe, recipeSHA256: recipeSHA256, in: directory)
        case .linux: try await buildLinux(recipe, recipeSHA256: recipeSHA256, in: directory)
        case .windows: try await buildWindows(recipe, recipeSHA256: recipeSHA256, in: directory)
        }
    }

    private func buildLinux(_ recipe: Recipe, recipeSHA256: String, in directory: URL) async throws -> VMConfig {
        let (image, sourceSHA256) = try await resolveSource(recipe.source)
        let machine = Machine(cpus: recipe.cpus, memory: recipe.memory.bytes, macAddress: .randomLocallyAdministered())
        var bundle = try LinuxVMBundle.create(at: directory, image: image, diskBytes: recipe.disk.bytes, log: log)
        let seed = try bundle.writeSeed(vmName: options.name)
        defer { try? FileManager.default.removeItem(at: seed) }
        bundle.seed = seed

        let version: String
        do {
            version = try await withVM(bundle, machine: machine) { vm, guest in
                log("Waiting for cloud-init to apply the guest conventions")
                try await guest.check(CloudInit.waitCommand, what: "cloud-init")
                let version = try await guest.output(#". /etc/os-release && echo "$NAME $VERSION_ID""#, what: "reading /etc/os-release")
                try await provisionAndShutDown(vm, shell: guest, recipe: recipe, cleanupScript: CloudInit.cleanupScript)
                return version
            }
        } catch {
            // The bundle, console.log included, is about to be deleted.
            logConsoleTail(bundle.consoleLog)
            throw error
        }
        log("Disk uses \(ByteCountFormatter.string(fromByteCount: Int64(bundle.allocatedDiskBytes()), countStyle: .file))")
        return VMConfig(
            os: .linux, cpus: machine.cpus, memory: machine.memory, disk: recipe.disk.bytes,
            macAddress: machine.macAddress.string, guestOSVersion: version,
            created: .now, recipeSHA256: recipeSHA256, sourceSHA256: sourceSHA256, nicMatchedByDriver: true
        )
    }

    private func buildWindows(_ recipe: Recipe, recipeSHA256: String, in directory: URL) async throws -> VMConfig {
        let (iso, sourceSHA256) = try await resolveSource(recipe.source)
        try WindowsInstallMedia.validate(iso)
        let resizable = recipe.windows.resizableDisplay
        let packages = try await fetchWindowsPackages(resizableDisplay: resizable)
        let machine = Machine(cpus: recipe.cpus, memory: recipe.memory.bytes, macAddress: .randomLocallyAdministered())
        var bundle = try WindowsVMBundle.create(at: directory, diskBytes: recipe.disk.bytes, resizableDisplay: resizable)

        log("Building the install media")
        let media = directory.appending(path: "install-media.img")
        defer { try? FileManager.default.removeItem(at: media) }
        try WindowsInstallMedia.create(
            at: media, iso: iso, packages: packages,
            computerName: WindowsGuest.computerName(for: options.name), timeZone: WindowsInstallMedia.hostTimeZone()
        )
        bundle.installMedia = media

        log("Installing Windows (a few minutes)")
        let installer = try GuestVM(bundle: bundle, machine: machine)
        try await installer.start()
        // Nothing in the guest can be asked how it's going, and its display is frozen on the logo.
        let stoppedItself = try await installer.waitForPowerOffOrForce(timeout: .seconds(30 * 60))
        try WindowsInstallMedia.checkResult(of: media)
        if !stoppedItself { throw VMError.timedOut("installing Windows") }
        bundle.installMedia = nil
        try? FileManager.default.removeItem(at: media)

        log("Waiting for Windows to finish setting up, and for the guest conventions")
        let version = try await withVM(bundle, machine: machine) { vm, guest in
            if resizable { try await followWindowsDisplay(guest) }
            let version = try await guest.output(WindowsGuest.versionCommand, what: "reading the Windows version")
            try await Provisioning.run(recipe, shell: guest, log: log)
            log("Cleaning up")
            try await guest.check(WindowsGuest.cleanupCommand, what: "cleanup")
            try await shutDown(vm, shell: guest)
            return version
        }
        log("Disk uses \(ByteCountFormatter.string(fromByteCount: Int64(bundle.allocatedDiskBytes()), countStyle: .file))")
        return VMConfig(
            os: .windows, cpus: machine.cpus, memory: machine.memory, disk: recipe.disk.bytes,
            macAddress: machine.macAddress.string, guestOSVersion: version,
            created: .now, recipeSHA256: recipeSHA256, sourceSHA256: sourceSHA256, resizableDisplay: resizable
        )
    }

    /// Windows starts at 1024×768 whatever the display offers, and remembers the size it's set to. From
    /// the next logon, `display-follower.ps1` keeps it at the display's size, which follows the window.
    private func followWindowsDisplay(_ guest: GuestAgent) async throws {
        let status = try await guest.exec(WindowsGuest.setDisplayCommand, gui: true, platform: WindowsVMBundle.self) { [log] _, data in
            log(String(decoding: data, as: UTF8.self))
        }
        if status != 0 { throw VMError.commandFailed("setting the display size", status) }
        try await guest.check(WindowsGuest.followDisplayCommand, what: "registering the display follower")
    }

    private func fetchWindowsPackages(resizableDisplay: Bool) async throws -> WindowsInstallMedia.PackageFiles {
        let images = ImageIndex.standard(home: home)
        let fetch = { (package: WindowsInstallMedia.PinnedPackage) async throws -> URL in
            try await images.fetch(package.url, expectedSHA256: package.sha256, log: log, progress: ProgressLine(log: log).report).file
        }
        return WindowsInstallMedia.PackageFiles(
            virtioWin: try await fetch(WindowsInstallMedia.virtioWin),
            openSSH: try await fetch(WindowsInstallMedia.openSSH),
            winFsp: try await fetch(WindowsInstallMedia.winFsp),
            vzDisplayDriver: resizableDisplay ? try await fetch(WindowsInstallMedia.vzDisplayDriver) : nil
        )
    }

    private func logConsoleTail(_ consoleLog: URL, lines: Int = 30) {
        guard let text = try? String(contentsOf: consoleLog, encoding: .utf8), !text.isEmpty else { return }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        log("Last lines of the guest's console:\n\(tail)")
    }

    private func buildMac(_ recipe: Recipe, recipeSHA256: String, in directory: URL) async throws -> VMConfig {
        let (ipsw, sourceSHA256) = try await resolveSource(recipe.source)
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VMError.unsupportedRestoreImage
        }
        let machine = Machine(
            cpus: max(recipe.cpus, requirements.minimumSupportedCPUCount),
            memory: max(recipe.memory.bytes, requirements.minimumSupportedMemorySize),
            macAddress: .randomLocallyAdministered()
        )
        let os = image.operatingSystemVersion

        let bundle = try MacVMBundle.create(at: directory, hardwareModel: requirements.hardwareModel, diskBytes: recipe.disk.bytes)
        try await installAndApplyConventions(bundle, ipsw: ipsw, machine: machine)
        if !recipe.security.sip {
            try await disableSIP(bundle, machine: machine, disableAMFI: !recipe.security.amfi)
        }
        // The conventions boot ended in a shutdown, so the disk is free to mount.
        log(recipe.guiTesting == nil
            ? "Granting hobo-agent Full Disk Access"
            : "Granting hobo-agent Full Disk Access, and GUI testing permissions (Accessibility, Screen Recording, Automation)")
        try GuestDataVolume.withMounted(bundle.disk) { volume in
            try GUITestingGrants.applyAgentAccess(dataVolume: volume)
            if let guiTesting = recipe.guiTesting {
                try GUITestingGrants.apply(GUITestingGrants.clients(allow: guiTesting.allow), dataVolume: volume)
            }
        }

        let security = try await withVM(bundle, machine: machine) { vm, guest in
            let security = try await checkSecurity(guest, wanted: recipe.security)
            if recipe.guiTesting != nil {
                log("Checking GUI testing permissions")
                try await guest.check(GUITestingGrants.checkCommand, what: "GUI testing permission check")
                try await guest.check(GUITestingGrants.seedScreenCaptureApprovalCommand, what: "seeding the Screen Recording approval")
            }
            try await provisionAndShutDown(vm, shell: guest, recipe: recipe, cleanupScript: Conventions.cleanupScript)
            return security
        }
        log("Disk uses \(ByteCountFormatter.string(fromByteCount: Int64(bundle.allocatedDiskBytes()), countStyle: .file))")
        return VMConfig(
            os: .macOS, cpus: machine.cpus, memory: machine.memory, disk: recipe.disk.bytes,
            macAddress: machine.macAddress.string,
            guestOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(image.buildVersion))",
            created: .now, recipeSHA256: recipeSHA256, sourceSHA256: sourceSHA256,
            sip: security.sip, amfi: security.amfi
        )
    }

    /// The end of every create: the recipe's steps, cleanup, and a clean shutdown.
    private func provisionAndShutDown(_ vm: GuestVM, shell guest: any GuestShell, recipe: Recipe, cleanupScript: String) async throws {
        try await Provisioning.run(recipe, shell: guest, log: log)
        log("Cleaning up")
        try await guest.upload(contents: cleanupScript, to: "/tmp/hobo-cleanup.sh")
        try await guest.check("sudo -n /bin/bash /tmp/hobo-cleanup.sh", what: "cleanup")
        try await shutDown(vm, shell: guest)
    }

    /// The hardware every boot of the VM uses: the recipe's values raised to the IPSW's minimums,
    /// and one MAC for the VM's life.
    fileprivate struct Machine {
        var cpus: Int
        var memory: UInt64
        var macAddress: VZMACAddress
    }

    private func resolveSource(_ source: Recipe.Source) async throws -> (file: URL, sha256: String) {
        let images = ImageIndex.standard(home: home)
        let progress = ProgressLine(log: log)
        switch source {
        case .latest:
            let image = try await VZMacOSRestoreImage.latestSupported
            log("warning: source is unpinned (ipsw = \"latest\"); resolved to \(image.url.absoluteString)")
            let fetched = try await images.fetch(image.url, expectedSHA256: nil, log: log, progress: progress.report)
            log("Pin it by replacing ipsw = \"latest\" in [source] with:\nipsw = \"\(image.url.absoluteString)\"\nsha256 = \"\(fetched.sha256)\"")
            return fetched
        case .remote(let url, let sha):
            return try await images.fetch(url, expectedSHA256: sha, log: log, progress: progress.report)
        case .local(let url, let sha):
            try images.verify(url, sha256: sha, log: log)
            return (url, sha)
        }
    }

    private func installAndApplyConventions(_ bundle: MacVMBundle, ipsw: URL, machine: Machine) async throws {
        let installer = try GuestVM(bundle: bundle, machine: machine)
        log("Installing macOS (this takes a while)")
        let progress = ProgressLine(log: log)
        try await installer.install(ipsw: ipsw) { progress.report(Int64($0 * 100), 100) }
        // The installer leaves its VM running; boot a fresh one for unattended setup.
        try await installer.forceStop()

        let vm = try GuestVM(bundle: bundle, machine: machine)

        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = Conventions.fullName
        provisioning.username = Conventions.username
        provisioning.password = Conventions.password
        provisioning.logsInAutomatically = Conventions.logsInAutomatically
        provisioning.enablesRemoteLogin = Conventions.enablesRemoteLogin
        log("First boot with unattended setup")
        try await vm.start(provisioning: provisioning)
        // Until the conventions script installs the insecure key, the guest only takes the password.
        let auth = GuestSSH.Auth.password(Conventions.password)
        do {
            let ip = try await vm.waitForIPAddress(timeout: .seconds(20 * 60))
            let ssh = GuestSSH(host: ip, auth: auth)
            try await ssh.waitUntilReachable(timeout: .seconds(20 * 60))
            // Passwordless sudo doesn't exist until the conventions script has run.
            let passwordSudo = "echo \(shellQuote(Conventions.password)) | sudo -S -p ''"
            log("Applying guest conventions")
            // The conventions script installs it as the stub, through which the rest of create runs.
            let agent = FileManager.default.temporaryDirectory.appending(path: "hobo-agent-\(UUID().uuidString)")
            try Payloads.agent("darwin").write(to: agent)
            defer { try? FileManager.default.removeItem(at: agent) }
            try await ssh.upload(agent, to: Conventions.agentUpload)
            try await ssh.upload(contents: Conventions.script, to: "/tmp/hobo-conventions.sh")
            try await ssh.check("\(passwordSudo) /bin/bash /tmp/hobo-conventions.sh && rm /tmp/hobo-conventions.sh", what: "conventions")
            log("Waiting for the first login")
            try await ssh.upload(contents: Conventions.waitForLoginScript, to: "/tmp/hobo-wait-login.sh")
            try await ssh.check("sudo -n /bin/bash /tmp/hobo-wait-login.sh && rm /tmp/hobo-wait-login.sh", what: "waiting for the first login")
            try await shutDown(vm, shell: ssh, command: "\(passwordSudo) shutdown -h now")
        } catch {
            try await holdForDebugging(vm, auth: auth, error: error)
            throw error
        }
    }

    /// Boots into recoveryOS for the person to run `csrutil disable` (`SIPRecoveryStep`), then boots
    /// normally to check it took, going round again if not, and sets the AMFI boot-arg over SSH,
    /// which works once SIP is off and takes effect from the next boot.
    private func disableSIP(_ bundle: MacVMBundle, machine: Machine, disableAMFI: Bool) async throws {
        var notice: String?
        while true {
            let vm = try GuestVM(bundle: bundle, machine: machine)
            log("Booting into recoveryOS to turn SIP off")
            try await vm.start(provisioning: nil, recovery: true)
            if await SIPRecoveryStep.run(vm, name: options.name, notice: notice, log: log) == .cancelled {
                try await vm.forceStop()
                throw VMError.cancelled
            }
            log("Checking that SIP is off")
            let disabled = try await withVM(bundle, machine: machine) { vm, guest in
                let disabled = try await guest.run(Self.sipDisabledCommand, quiet: true) == 0
                if disabled, disableAMFI {
                    log("Turning AMFI off (boot-arg amfi_get_out_of_my_way=1)")
                    try await guest.check("sudo -n nvram boot-args=\(Self.amfiBootArg)", what: "setting the AMFI boot-arg")
                }
                try await shutDown(vm, shell: guest)
                return disabled
            }
            if disabled { return }
            log("SIP is still on; back to recoveryOS")
            notice = "SIP is still on: csrutil disable didn't finish last time. Please go through the steps again."
        }
    }

    static let amfiBootArg = "amfi_get_out_of_my_way=1"
    static let sipDisabledCommand = "csrutil status | grep -q 'status: disabled'"

    /// What the guest actually runs with, for `config.json`; fails if it isn't what the recipe asked.
    private func checkSecurity(_ guest: any GuestShell, wanted: Recipe.Security) async throws -> Recipe.Security {
        let actual = Recipe.Security(
            sip: try await guest.run(Self.sipDisabledCommand, quiet: true) != 0,
            amfi: try await guest.run("sysctl -n kern.bootargs | grep -qw \(Self.amfiBootArg)", quiet: true) != 0
        )
        if actual != wanted { throw VMError.securityMismatch(wanted: wanted, actual: actual) }
        return actual
    }

    /// Boots the bundle, reaches it through its agent (or logs in with its key), runs `body`, and
    /// expects it to shut the VM down.
    private func withVM<T>(_ bundle: any VMBundle, machine: Machine, _ body: (GuestVM, GuestAgent) async throws -> T) async throws -> T {
        let auth = try GuestSSH.Auth.forVM(bundle: bundle.directory, home: home)
        let vm = try GuestVM(bundle: bundle, machine: machine)
        log("Booting")
        try await vm.start()
        do {
            let shell = vm.agent
            try await shell.waitUntilReachable(timeout: .seconds(10 * 60))
            return try await body(vm, shell)
        } catch {
            try await holdForDebugging(vm, auth: auth, error: error)
            throw error
        }
    }

    /// `command` is for when the guest's usual one (`VMBundle.shutdownCommand`) won't do yet.
    private func shutDown(_ vm: GuestVM, shell guest: any GuestShell, command: String? = nil) async throws {
        log("Shutting down")
        // The connection usually drops mid-command here; the VM state is what matters.
        _ = try? await guest.run(command ?? type(of: vm.bundle).shutdownCommand, quiet: true)
        if try await !vm.waitForPowerOffOrForce(timeout: .seconds(5 * 60)) {
            log("warning: guest did not power off within 5 minutes; forced it off")
        }
    }

    /// With `holdOnFailure`, keeps a failed create's VM up for SSH until ^C (which deletes it).
    private func holdForDebugging(_ vm: GuestVM, auth: GuestSSH.Auth, error: Error) async throws {
        log("Create failed: \(error)")
        guard !vm.isStopped else { return }
        if options.holdOnFailure, let ip = DHCPLeases.ipAddress(forMAC: vm.macAddress.string) {
            let ssh = GuestSSH(host: ip, auth: auth)
            let password = if case .password(let password) = auth { " (password: \(password))" } else { "" }
            log("VM left running for debugging; press ^C to stop and delete it:\n  \(ssh.commandLine())\(password)")
            while !vm.isStopped { try await Task.sleep(for: .seconds(1)) }
        }
        try await vm.forceStop()
    }
}

extension GuestVM {
    fileprivate convenience init(bundle: any VMBundle, machine: VMCreator.Machine) throws {
        try self.init(bundle: bundle, cpus: machine.cpus, memoryBytes: machine.memory, macAddress: machine.macAddress)
    }
}

/// While a create runs, ^C or SIGTERM deletes the half-built bundle and exits. The VM runs in this
/// process, so it goes with it. Handled off the main queue, which a long hash can block.
private final class InterruptCleanup: Sendable {
    private let sources: [any DispatchSourceSignal]

    init(bundle: URL, interrupted: @escaping @Sendable (String) -> Void) {
        sources = [SIGINT, SIGTERM].map { signo in
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
            source.setEventHandler {
                interrupted("deleting \(bundle.path)")
                WindowsInstallMedia.ejectAttached()
                try? FileManager.default.removeItem(at: bundle)
                exit(128 + signo)
            }
            source.resume()
            return source
        }
    }

    func cancel() {
        for source in sources {
            source.cancel()
            signal(Int32(source.handle), SIG_DFL)
        }
    }
}

/// Logs progress at 10% steps so a 30-minute download or install stays quiet but alive.
private final class ProgressLine: Sendable {
    private let log: @Sendable (String) -> Void
    private let lastDecile = Mutex(-1)

    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    func report(_ done: Int64, _ total: Int64) {
        guard total > 0 else { return }
        let decile = Int(done * 10 / total)
        let shouldLog = lastDecile.withLock { last in
            guard decile > last else { return false }
            last = decile
            return true
        }
        if shouldLog { log("  \(decile * 10)%") }
    }
}
