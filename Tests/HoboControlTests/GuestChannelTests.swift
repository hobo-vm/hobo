import Foundation
import HoboCore
import Synchronization
import Testing
@testable import HoboControl

/// `GuestChannel` against a fake launchd and a real control socket standing in for the VM process.
@Suite struct GuestChannelTests {
    let launchctl = VMLifecycleTests.FakeLaunchctl()
    let store: VMStore
    let channel: GuestChannel

    init() throws {
        // Short, since the socket lives in the home and socket paths are capped at 103 bytes.
        let home = HoboHome(root: URL(filePath: "/tmp/hobo-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        store = VMStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "hobo-vms-\(UUID().uuidString)"),
            home: home, launchd: launchctl.launchd
        )
        _ = try store.beginCreate("dev")
        try store.finishCreate("dev", config: VMConfig(
            engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
            guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 1_800_000_000),
            recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
        ), recipe: Data("cpus = 4\n".utf8))
        channel = GuestChannel(store: store)
        let label = store.job(for: "dev").label
        launchctl.label.withLock { $0 = label }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: store.directory)
        try? FileManager.default.removeItem(at: store.home.root)
    }

    func serve(_ handler: @escaping ControlServer.Handler) throws -> ControlServer {
        launchctl.pid.withLock { $0 = 4242 }
        return try ControlServer(path: store.job(for: "dev").socket, handler: handler)
    }

    /// Runs a blocking client call on a GCD thread. The fake VM process's handler needs Swift
    /// concurrency's pool, which parallel tests blocking on their own clients can otherwise exhaust.
    func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result(catching: body)) }
        }
    }

    @Test func refusesAStoppedVM() {
        defer { cleanUp() }
        #expect(throws: GuestChannelError.notRunning("dev")) { try channel.ipAddress("dev") }
        #expect(throws: GuestChannelError.notRunning("dev")) { try channel.exec("dev", command: ["true"]) { _, _ in } }
    }

    @Test func reportsTheIPOrWhyThereIsNone() async throws {
        defer { cleanUp() }
        let channel = channel
        let ip = try serve { _, _ in .status(VMRunStatus(state: .running, pid: 4242, ipAddress: "192.168.64.5")) }
        #expect(try await offPool { try channel.ipAddress("dev") } == "192.168.64.5")
        #expect(try await offPool { try channel.address("DEV") } == GuestAddress(name: "dev", ipAddress: "192.168.64.5"), "the stored name, not the one typed")
        ip.close()
        let none = try serve { _, _ in .status(VMRunStatus(state: .starting, pid: 4242, detail: "booting")) }
        defer { none.close() }
        await #expect(throws: GuestChannelError.noIPAddress("dev", "booting")) { try await offPool { try channel.ipAddress("dev") } }
    }

    /// Whoever asks for the IP is about to use the guest over SSH, which the VM process can't see.
    @Test func askingForTheIPRenewsTheIdleTimeout() async throws {
        defer { cleanUp() }
        let channel = channel
        let requests = Mutex<[ControlRequest]>([])
        let server = try serve { request, _ in
            requests.withLock { $0.append(request) }
            return .status(VMRunStatus(state: .running, pid: 4242, ipAddress: "192.168.64.5"))
        }
        defer { server.close() }
        _ = try await offPool { try channel.ipAddress("dev") }
        #expect(requests.withLock { $0 } == [.renew])
    }

    /// `hobo provision` works over its own SSH, for longer than an idle timeout may last.
    @Test func renewingKeepsRenewingUntilTheWorkEnds() async throws {
        defer { cleanUp() }
        let requests = Mutex<[ControlRequest]>([])
        let server = try serve { request, _ in
            requests.withLock { $0.append(request) }
            return .status(VMRunStatus(state: .running, pid: 4242))
        }
        defer { server.close() }
        try await channel.renewing("dev", every: .milliseconds(5)) {
            while requests.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(requests.withLock { $0.allSatisfy { $0 == .renew } })
        try await Task.sleep(for: .milliseconds(50)) // Lets a renewal already sent arrive.
        let settled = requests.withLock { $0.count }
        try await Task.sleep(for: .milliseconds(50))
        #expect(requests.withLock { $0.count } == settled)
    }

    @Test func renewingOutlivesAVMThatDoesntAnswer() async throws {
        defer { cleanUp() }
        let ran = Mutex(false)
        try await channel.renewing("dev", every: .milliseconds(1)) {
            try await Task.sleep(for: .milliseconds(20))
            ran.withLock { $0 = true }
        }
        #expect(ran.withLock { $0 })
    }

    @Test func execPassesOutputAndReturnsTheExitStatus() throws {
        defer { cleanUp() }
        let server = try serve { _, reply in
            try? reply.send(.output(.stdout, Data("hi\n".utf8)))
            return .exited(7)
        }
        defer { server.close() }
        var output = Data()
        #expect(try channel.exec("dev", command: ["echo", "hi"]) { _, data in output += data } == 7)
        #expect(output == Data("hi\n".utf8))
    }

    @Test func aRefusalIsAnError() throws {
        defer { cleanUp() }
        let server = try serve { _, _ in .error("dev is stopping") }
        defer { server.close() }
        let copy = GuestCopy(direction: .toGuest, sources: ["/a"], destination: "/tmp/", recursive: false)
        #expect(throws: LifecycleError.refused("dev", "dev is stopping")) { try channel.copy("dev", copy) { _, _ in } }
    }
}

/// The shapes `hobo ip --json`, `exec --json` and `cp --json` print, which scripts depend on.
@Suite struct GuestResultJSONTests {
    private func json(_ value: some Encodable) throws -> String { String(decoding: try HoboJSON.line(value), as: UTF8.self) }

    @Test func shapes() throws {
        #expect(try json(GuestAddress(name: "dev", ipAddress: "192.168.64.5")) == #"{"ipAddress":"192.168.64.5","name":"dev"}"#)
        #expect(try json(GuestCommandResult(exitStatus: 7)) == #"{"exitStatus":7}"#)
    }
}
