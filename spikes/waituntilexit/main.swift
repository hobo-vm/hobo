// Spike: can -[NSTask waitUntilExit] miss a child's exit and block forever?
// Usage: spike <variant> <iterations> <concurrency>
//   plain    /usr/bin/true, waitUntilExit, from a Swift-concurrency task
//   hosttar  HostTar's shape: tar -x reading a stdin pipe, stderr collected on a detached thread
//   thread   plain, but each wait on its own detached Thread
//   handler  plain, but waits on a terminationHandler semaphore (the fix)
//   hop      launched in a task, waited on after an await that hops threads (as GuestAgent.get does)
//   hopfix   hop, but waiting on a terminationHandler semaphore
//   gone     launched on a detached thread that then exits; waited on from a task
// A wait that hasn't returned 10 s after its process launched counts as hung.
import Foundation

final class Tracker: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [Int: Date] = [:]
    private(set) var done = 0
    private(set) var hops = 0
    private var hoppedSet: Set<Int> = []
    private var waitStart: [Int: Date] = [:]
    private(set) var slowest: TimeInterval = 0
    func hopped(_ i: Int) { lock.withLock { hops += 1; hoppedSet.insert(i) } }
    func didHop(_ i: Int) -> Bool { lock.withLock { hoppedSet.contains(i) } }
    func begin(_ i: Int) { lock.withLock { started[i] = Date(); waitStart[i] = Date() } }
    func end(_ i: Int) { lock.withLock {
        started[i] = nil; done += 1
        if let s = waitStart.removeValue(forKey: i) { slowest = max(slowest, -s.timeIntervalSinceNow) }
    } }
    func stuck(after seconds: TimeInterval) -> [Int] {
        lock.withLock { started.filter { -$0.value.timeIntervalSinceNow > seconds }.map(\.key).sorted() }
    }
}

func plain(_ i: Int, _ t: Tracker) throws {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/true")
    try p.run()
    t.begin(i)
    p.waitUntilExit()
    t.end(i)
}

func handler(_ i: Int, _ t: Tracker) throws {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/true")
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    try p.run()
    t.begin(i)
    exited.wait()
    t.end(i)
}

/// Runs `body` on a fresh detached thread and resumes once it returns, so the caller continues
/// wherever the executor puts it: usually not the thread it left.
func elsewhere<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in Thread.detachNewThread { c.resume(with: Result { try body() }) } }
}

func hop(_ i: Int, _ t: Tracker) async throws {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/true")
    try p.run()
    let launchedOn = pthread_self()
    try await elsewhere { usleep(UInt32.random(in: 0...2000)) }
    if pthread_equal(launchedOn, pthread_self()) == 0 { t.hopped(i) }
    t.begin(i)
    p.waitUntilExit()
    t.end(i)
}

func hopfix(_ i: Int, _ t: Tracker) async throws {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/true")
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    try p.run()
    let launchedOn = pthread_self()
    try await elsewhere { usleep(UInt32.random(in: 0...2000)) }
    if pthread_equal(launchedOn, pthread_self()) == 0 { t.hopped(i) }
    t.begin(i)
    exited.wait()
    t.end(i)
}

func gone(_ i: Int, _ t: Tracker) async throws {
    let p = try await elsewhere { () -> Process in
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/true")
        try p.run()
        return p
    }
    t.begin(i)
    p.waitUntilExit()
    t.end(i)
}

let archive: Data = {
    let dir = FileManager.default.temporaryDirectory.appending(path: "spike-src-\(getpid())")
    try? FileManager.default.createDirectory(at: dir.appending(path: "tree"), withIntermediateDirectories: true)
    try? Data("a".utf8).write(to: dir.appending(path: "tree/a.txt"))
    let p = Process(), out = Pipe()
    p.executableURL = URL(filePath: "/usr/bin/tar")
    p.arguments = ["-c", "-f", "-", "-C", dir.path, "tree"]
    p.standardOutput = out
    try! p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}()

func hosttar(_ i: Int, _ t: Tracker) throws {
    let dest = FileManager.default.temporaryDirectory.appending(path: "spike-\(getpid())-\(i)")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dest) }
    let p = Process(), input = Pipe(), errors = Pipe()
    p.executableURL = URL(filePath: "/usr/bin/tar")
    p.arguments = ["-x", "-f", "-", "-C", dest.path]
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = errors
    try p.run()
    let collected = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        collected.signal()
    }
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try input.fileHandleForWriting.write(contentsOf: archive)
    try input.fileHandleForWriting.close()
    collected.wait()
    t.begin(i)
    p.waitUntilExit()
    t.end(i)
}

@main struct Spike {
    static func main() async throws {
        let args = CommandLine.arguments
        let variant = args.count > 1 ? args[1] : "plain"
        let iterations = args.count > 2 ? Int(args[2])! : 2000
        let width = args.count > 3 ? Int(args[3])! : 8
        let body: @Sendable (Int, Tracker) async throws -> Void = switch variant {
        case "plain", "thread": plain
        case "hosttar": hosttar
        case "handler": handler
        case "hop": hop
        case "hopfix": hopfix
        case "gone": gone
        default: fatalError("unknown variant \(variant)")
        }
        let tracker = Tracker()
        let begun = Date()

        // Watchdog on a plain thread, so it runs even if every cooperative thread is stuck.
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 2)
                let stuck = tracker.stuck(after: 10)
                if !stuck.isEmpty {
                    print("HUNG: \(variant): \(stuck.count) wait(s) stuck >10s (iterations \(stuck.prefix(5)), \(stuck.filter(tracker.didHop).count) launched on another thread) after \(tracker.done) completed in \(Int(-begun.timeIntervalSinceNow))s")
                    exit(2)
                }
            }
        }

        if variant == "thread" {
            let gate = DispatchSemaphore(value: width), all = DispatchGroup()
            for i in 0..<iterations {
                gate.wait(); all.enter()
                Thread.detachNewThread { try! plain(i, tracker); gate.signal(); all.leave() }
            }
            all.wait()
        } else {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<iterations {
                    if i >= width { try await group.next() }
                    group.addTask { try await body(i, tracker) }
                }
                try await group.waitForAll()
            }
        }
        print("ok: \(variant): \(tracker.done) waits returned in \(String(format: "%.1f", -begun.timeIntervalSinceNow))s\(variant.hasPrefix("hop") ? ", \(tracker.hops) on another thread" : ""), slowest wait \(String(format: "%.2f", tracker.slowest))s")
    }
}
