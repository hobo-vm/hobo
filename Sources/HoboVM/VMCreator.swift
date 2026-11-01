import Foundation
import HoboCore
import Synchronization
import Virtualization

/// Builds a macOS VM from a recipe, in place in a directory: IPSW → unattended install → Vagrant
/// conventions → recipe steps → cleanup → clean shutdown. Every create is a full install.
@MainActor
public struct VMCreator {
    public struct Options: Sendable {
        /// Where the VM is built and left. Created if missing.
        public var directory: URL
        /// On failure, leave the VM running for SSH until interrupted.
        public var holdOnFailure: Bool

        public init(directory: URL, holdOnFailure: Bool = false) {
            self.directory = directory
            self.holdOnFailure = holdOnFailure
        }
    }

    public struct Result: Sendable {
        public var bundle: MacVMBundle
        /// The recipe's values raised to the IPSW's minimums.
        public var cpus: Int
        public var memoryBytes: UInt64
        /// e.g. `27.2.0 (26B123)`.
        public var guestOSVersion: String
    }

    let recipe: Recipe
    let home: HoboHome
    let options: Options
    let log: @Sendable (String) -> Void

    public init(recipe: Recipe, home: HoboHome = .standard(), options: Options, log: @escaping @Sendable (String) -> Void) {
        self.recipe = recipe
        self.home = home
        self.options = options
        self.log = log
    }

    public func create() async throws -> Result {
        try recipe.checkFilesExist()

        let ipsw = try await resolveSource()
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VMError.unsupportedRestoreImage
        }
        let cpus = max(recipe.cpus, requirements.minimumSupportedCPUCount)
        let memory = max(recipe.memory.bytes, requirements.minimumSupportedMemorySize)
        let os = image.operatingSystemVersion
        let guestVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(image.buildVersion))"

        let bundle = try MacVMBundle.create(at: options.directory, hardwareModel: requirements.hardwareModel, diskBytes: recipe.disk.bytes)
        try await installAndApplyConventions(bundle, ipsw: ipsw, cpus: cpus, memory: memory)

        try await withVM(bundle, cpus: cpus, memory: memory) { vm, ssh in
            for (index, step) in recipe.provisioners.enumerated() {
                log("Provision step \(index + 1)/\(recipe.provisioners.count) (\(step.type.rawValue))")
                try await provision(step, index: index, ssh: ssh)
            }
            log("Cleaning up")
            try await ssh.upload(contents: Conventions.cleanupScript, to: "/tmp/hobo-cleanup.sh")
            try await ssh.check("sudo -n /bin/bash /tmp/hobo-cleanup.sh", what: "cleanup")
            try await shutDown(vm, ssh: ssh)
        }
        log("Disk uses \(ByteCountFormatter.string(fromByteCount: Int64(bundle.allocatedDiskBytes()), countStyle: .file))")
        return Result(bundle: bundle, cpus: cpus, memoryBytes: memory, guestOSVersion: guestVersion)
    }

    private func resolveSource() async throws -> URL {
        let depot = Depot(directory: home.depot)
        let progress = ProgressLine(log: log)
        switch recipe.source {
        case .latest:
            let image = try await VZMacOSRestoreImage.latestSupported
            log("warning: source is unpinned (ipsw = \"latest\"); resolved to \(image.url.absoluteString)")
            let (file, sha) = try await depot.fetch(image.url, expectedSHA256: nil, progress: progress.report)
            log("Pin it with: ipsw = \"\(image.url.absoluteString)\", sha256 = \"\(sha)\"")
            return file
        case .remote(let url, let sha):
            return try await depot.fetch(url, expectedSHA256: sha, progress: progress.report).file
        case .local(let url, let sha):
            log("Verifying \(url.lastPathComponent)")
            try Depot.verify(url, sha256: sha)
            return url
        }
    }

    private func installAndApplyConventions(_ bundle: MacVMBundle, ipsw: URL, cpus: Int, memory: UInt64) async throws {
        let installer = try GuestVM(bundle: bundle, cpus: cpus, memoryBytes: memory)
        log("Installing macOS (this takes a while)")
        let progress = ProgressLine(log: log)
        try await installer.install(ipsw: ipsw) { progress.report(Int64($0 * 100), 100) }
        // The installer leaves its VM running; boot a fresh one for unattended setup.
        try await installer.forceStop()

        let vm = try GuestVM(bundle: bundle, cpus: cpus, memoryBytes: memory)

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
    private func withVM(_ bundle: MacVMBundle, cpus: Int, memory: UInt64, _ body: (GuestVM, GuestSSH) async throws -> Void) async throws {
        let auth = GuestSSH.Auth.key(try home.ensureInsecurePrivateKey())
        let vm = try GuestVM(bundle: bundle, cpus: cpus, memoryBytes: memory)
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

    private func provision(_ step: Provisioner, index: Int, ssh: GuestSSH) async throws {
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

    /// Prints how to get into a failed create, and with `holdOnFailure` keeps the VM up until ^C.
    private func holdForDebugging(_ vm: GuestVM, auth: GuestSSH.Auth, error: Error) async throws {
        log("Create failed: \(error)")
        log("VM kept at \(vm.bundle.directory.path)")
        guard !vm.isStopped else { return }
        if options.holdOnFailure, let ip = DHCPLeases.ipAddress(forMAC: vm.macAddress.string) {
            let ssh = GuestSSH(host: ip, auth: auth)
            let password = if case .password(let password) = auth { " (password: \(password))" } else { "" }
            log("VM left running for debugging; press ^C to stop it:\n  \(ssh.commandLine)\(password)")
            while !vm.isStopped { try await Task.sleep(for: .seconds(1)) }
        }
        try await vm.forceStop()
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
