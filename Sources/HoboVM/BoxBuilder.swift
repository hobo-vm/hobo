import Foundation
import HoboCore
import Synchronization
import Virtualization

/// `hobo box build`: IPSW → unattended install → Vagrant conventions → recipe steps → cleanup →
/// `.box`. Work happens in the roundhouse; the post-conventions disk is checkpointed so rebuilds
/// only rerun recipe steps.
@MainActor
public struct BoxBuilder {
    public struct Options: Sendable {
        public var output: URL
        /// Ignore any checkpoint and reinstall from the IPSW.
        public var fresh = false
        /// On failure, leave the VM running for SSH until interrupted.
        public var holdOnFailure = false

        public init(output: URL, fresh: Bool = false, holdOnFailure: Bool = false) {
            self.output = output
            self.fresh = fresh
            self.holdOnFailure = holdOnFailure
        }
    }

    public struct Result: Sendable {
        public var box: URL
        public var checksum: URL
        public var metadata: BoxMetadata
    }

    let recipe: Recipe
    let recipeFile: URL
    let home: HoboHome
    let options: Options
    let log: @Sendable (String) -> Void

    public init(recipeFile: URL, home: HoboHome = .standard(), options: Options, log: @escaping @Sendable (String) -> Void) throws {
        recipe = try Recipe.load(from: recipeFile)
        self.recipeFile = recipeFile
        self.home = home
        self.options = options
        self.log = log
    }

    public func build() async throws -> Result {
        try recipe.checkFilesExist()

        let (ipsw, ipswSHA) = try await resolveSource()
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VMError.unsupportedRestoreImage
        }
        let cpus = max(recipe.cpus, requirements.minimumSupportedCPUCount)
        let memory = max(recipe.memory.bytes, requirements.minimumSupportedMemorySize)
        let os = image.operatingSystemVersion
        let guestVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(image.buildVersion))"

        let work = home.roundhouse.appending(path: recipe.slug)
        try? FileManager.default.removeItem(at: work)
        let checkpoint = home.checkpoints.appending(path: Checkpoint.key(ipswSHA256: ipswSHA, diskBytes: recipe.disk.bytes))

        let bundle: MacVMBundle
        if !options.fresh, FileManager.default.fileExists(atPath: MacVMBundle(directory: checkpoint).disk.path) {
            log("Reusing install checkpoint \(checkpoint.lastPathComponent)")
            bundle = try MacVMBundle(directory: checkpoint).clone(to: work)
        } else {
            bundle = try MacVMBundle.create(at: work, hardwareModel: requirements.hardwareModel, diskBytes: recipe.disk.bytes)
            try await installAndApplyConventions(bundle, ipsw: ipsw, cpus: cpus, memory: memory)
            try saveCheckpoint(bundle, at: checkpoint)
        }

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

        let metadata = BoxMetadata(
            name: recipe.name, version: recipe.version, description: recipe.description, guestOSVersion: guestVersion,
            cpus: cpus, memory: ByteSize(bytes: memory).description, disk: recipe.disk.description,
            contentSHA256: try BoxMetadata.contentHash(of: bundle.files),
            recipeSHA256: try Depot.sha256(of: recipeFile)
        )
        let result = try package(bundle, metadata: metadata)
        try FileManager.default.removeItem(at: work)
        return result
    }

    private func resolveSource() async throws -> (URL, String) {
        let depot = Depot(directory: home.depot)
        let progress = ProgressLine(log: log)
        switch recipe.source {
        case .latest:
            let image = try await VZMacOSRestoreImage.latestSupported
            log("warning: source is unpinned (ipsw = \"latest\"); resolved to \(image.url.absoluteString)")
            let (file, sha) = try await depot.fetch(image.url, expectedSHA256: nil, progress: progress.report)
            log("Pin it with: ipsw = \"\(image.url.absoluteString)\", sha256 = \"\(sha)\"")
            return (file, sha)
        case .remote(let url, let sha):
            return try await (depot.fetch(url, expectedSHA256: sha, progress: progress.report).file, sha)
        case .local(let url, let sha):
            log("Verifying \(url.lastPathComponent)")
            try Depot.verify(url, sha256: sha)
            return (url, sha)
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
        provisioning.logsInAutomatically = true
        provisioning.enablesRemoteLogin = true
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
            let env = (step.env ?? [:]).sorted { $0.key < $1.key }.map { shellQuote("\($0.key)=\($0.value)") }
            let prefix = (step.privileged ?? true) ? ["sudo", "-n", "-H"] : []
            let command = (prefix + ["env"] + env + ["/bin/bash", "-l", remote]).joined(separator: " ")
            try await ssh.check(command, what: "provision step \(index + 1)")
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

    private func saveCheckpoint(_ bundle: MacVMBundle, at checkpoint: URL) throws {
        // Unique per build, so two builds saving the same checkpoint don't clone into one directory.
        let staging = checkpoint.appendingPathExtension("partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try bundle.clone(to: staging)
        try? FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.moveItem(at: staging, to: checkpoint)
        log("Saved install checkpoint \(checkpoint.lastPathComponent)")
    }

    private func package(_ bundle: MacVMBundle, metadata: BoxMetadata) throws -> Result {
        try metadata.encoded().write(to: bundle.directory.appending(path: BoxMetadata.fileName))
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let box = options.output.appending(path: recipe.boxFileName)
        log("Packaging \(box.path)")
        try run("/usr/bin/tar", ["-cf", box.path, "-C", bundle.directory.path, BoxMetadata.fileName] + MacVMBundle.platformFiles)
        let checksum = box.appendingPathExtension("sha256")
        try "\(try Depot.sha256(of: box))  \(box.lastPathComponent)\n".write(to: checksum, atomically: true, encoding: .utf8)
        return Result(box: box, checksum: checksum, metadata: metadata)
    }

    /// Prints how to get into a failed build, and with `holdOnFailure` keeps the VM up until ^C.
    private func holdForDebugging(_ vm: GuestVM, auth: GuestSSH.Auth, error: Error) async throws {
        log("Build failed: \(error)")
        log("Working directory kept at \(vm.bundle.directory.path)")
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
