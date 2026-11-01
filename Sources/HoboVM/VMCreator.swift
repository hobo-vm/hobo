import Foundation
import HoboCore
import Synchronization
import Virtualization

/// Creates a named macOS VM from a recipe, built in place in its bundle: IPSW → unattended install
/// → Vagrant conventions → recipe steps → cleanup → clean shutdown. Every create is a full install.
/// A failed or interrupted (^C) create deletes the bundle.
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

    public init(store: VMStore = .standard(), home: HoboHome = .standard(), options: Options, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.home = home
        self.options = options
        self.log = log
    }

    public func create() async throws -> VMConfig {
        let recipeData = try Data(contentsOf: options.recipeFile)
        let recipe = try Recipe.load(from: options.recipeFile)
        try recipe.checkFilesExist()

        let directory = try store.beginCreate(options.name)
        let interrupts = InterruptCleanup(bundle: directory, log: log)
        defer { interrupts.cancel() }
        do {
            log("Creating \(options.name) from \(options.recipeFile.path) in \(directory.path)")
            let config = try await build(recipe, recipeSHA256: VMStore.sha256(recipeData), in: directory)
            try store.finishCreate(options.name, config: config, recipe: recipeData)
            return config
        } catch {
            do {
                try store.abandonCreate(options.name)
                log("Deleted \(directory.path)")
            } catch let cleanupError {
                log("warning: could not delete \(directory.path): \(cleanupError)")
            }
            throw error
        }
    }

    private func build(_ recipe: Recipe, recipeSHA256: String, in directory: URL) async throws -> VMConfig {
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

        try await withVM(bundle, machine: machine) { vm, ssh in
            for (index, step) in recipe.provisioners.enumerated() {
                log("Provision step \(index + 1)/\(recipe.provisioners.count) (\(step.type.rawValue))")
                try await provision(step, index: index, recipe: recipe, ssh: ssh)
            }
            log("Cleaning up")
            try await ssh.upload(contents: Conventions.cleanupScript, to: "/tmp/hobo-cleanup.sh")
            try await ssh.check("sudo -n /bin/bash /tmp/hobo-cleanup.sh", what: "cleanup")
            try await shutDown(vm, ssh: ssh)
        }
        log("Disk uses \(ByteCountFormatter.string(fromByteCount: Int64(bundle.allocatedDiskBytes()), countStyle: .file))")
        return VMConfig(
            engine: .vz, os: .macOS, cpus: machine.cpus, memory: machine.memory, disk: recipe.disk.bytes,
            macAddress: machine.macAddress.string,
            guestOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(image.buildVersion))",
            created: .now, recipeSHA256: recipeSHA256, sourceSHA256: sourceSHA256
        )
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
            log("Applying Vagrant conventions")
            try await ssh.upload(contents: Conventions.script, to: "/tmp/hobo-conventions.sh")
            try await ssh.check("\(passwordSudo) /bin/bash /tmp/hobo-conventions.sh && rm /tmp/hobo-conventions.sh", what: "conventions")
            try await shutDown(vm, ssh: ssh, sudo: passwordSudo)
        } catch {
            try await holdForDebugging(vm, auth: auth, error: error)
            throw error
        }
    }

    /// Boots the bundle with the insecure key, runs `body`, and expects it to shut the VM down.
    private func withVM(_ bundle: MacVMBundle, machine: Machine, _ body: (GuestVM, GuestSSH) async throws -> Void) async throws {
        let auth = GuestSSH.Auth.key(try home.ensureInsecurePrivateKey())
        let vm = try GuestVM(bundle: bundle, machine: machine)
        log("Booting")
        try await vm.start()
        do {
            let ip = try await vm.waitForIPAddress(timeout: .seconds(10 * 60))
            let ssh = GuestSSH(host: ip, auth: auth)
            try await ssh.waitUntilReachable(timeout: .seconds(10 * 60))
            try await body(vm, ssh)
        } catch {
            try await holdForDebugging(vm, auth: auth, error: error)
            throw error
        }
    }

    private func provision(_ step: Provisioner, index: Int, recipe: Recipe, ssh: GuestSSH) async throws {
        switch step.type {
        case .shell:
            let remote = "/tmp/hobo-provision-\(index + 1).sh"
            if let inline = step.inline {
                try await ssh.upload(contents: inline + "\n", to: remote)
            } else if let path = step.path {
                try await ssh.upload(recipe.resolve(path), to: remote)
            }
            try await ssh.check(step.shellCommand(running: remote), what: "provision step \(index + 1)")
        case .file:
            guard let source = step.source, let destination = step.destination else { return }
            try await ssh.upload(recipe.resolve(source), to: destination)
        }
    }

    private func shutDown(_ vm: GuestVM, ssh: GuestSSH, sudo: String = "sudo -n") async throws {
        log("Shutting down")
        // ssh usually drops mid-command here; the VM state is what matters.
        try await ssh.run("\(sudo) shutdown -h now", quiet: true)
        if try await !vm.waitUntilStopped(timeout: .seconds(5 * 60)) {
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
            log("VM left running for debugging; press ^C to stop and delete it:\n  \(ssh.commandLine)\(password)")
            while !vm.isStopped { try await Task.sleep(for: .seconds(1)) }
        }
        try await vm.forceStop()
    }
}

extension GuestVM {
    fileprivate convenience init(bundle: MacVMBundle, machine: VMCreator.Machine) throws {
        try self.init(bundle: bundle, cpus: machine.cpus, memoryBytes: machine.memory, macAddress: machine.macAddress)
    }
}

/// While a create runs, ^C or SIGTERM deletes the half-built bundle and exits. The VM runs in this
/// process, so it goes with it. Handled off the main queue, which a long hash can block.
private final class InterruptCleanup: Sendable {
    private let sources: [any DispatchSourceSignal]

    init(bundle: URL, log: @escaping @Sendable (String) -> Void) {
        sources = [SIGINT, SIGTERM].map { signo in
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
            source.setEventHandler {
                log("\nInterrupted; deleting \(bundle.path)")
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
