import Foundation
import Testing
@testable import HoboCore

@Suite struct DiskUsageTests {
    private typealias Holder = DiskUsage.Holder

    private func extents(_ ranges: Range<Int64>..., device: Int32 = 1, unmapped: UInt64 = 0) -> FileExtents {
        FileExtents(mapped: ranges.map { .init(device: device, range: $0) }, unmappedBytes: unmapped)
    }

    // MARK: Counting, on made-up extents

    @Test func aBlockClonesShareCountsOnce() {
        let usage = DiskUsage.measure([(.vm("a"), extents(0..<100)), (.vm("b"), extents(0..<80, 200..<220))])
        #expect(usage.totalBytes == 120)
        #expect(usage.totalSnapshotBytes == 0)
    }

    @Test func snapshotsCountWhatTheirVMDoesNotHold() {
        let usage = DiskUsage.measure([
            (.vm("dev"), extents(0..<100)),
            (.snapshot(vm: "dev", tag: "old"), extents(50..<150, 300..<310)),
            (.snapshot(vm: "dev", tag: "new"), extents(100..<150, 400..<420)),
        ])
        #expect(usage.totalBytes == 180)
        #expect(usage.snapshotBytes["dev"] == 80)
        #expect(usage.totalSnapshotBytes == 80)
        // 100..<150 is in both, so deleting either alone frees none of it.
        #expect(usage.uniqueBytes["dev"]?["old"] == 10)
        #expect(usage.uniqueBytes["dev"]?["new"] == 20)
    }

    @Test func aSnapshotBlockAnotherVMHoldsIsNotUniqueToIt() {
        let usage = DiskUsage.measure([
            (.vm("a"), extents(0..<10)),
            (.snapshot(vm: "a", tag: "s"), extents(100..<200)),
            (.vm("clone"), extents(100..<200)),
        ])
        #expect(usage.totalBytes == 110)
        #expect(usage.snapshotBytes["a"] == 100)
        #expect(usage.totalSnapshotBytes == 0)
        #expect(usage.uniqueBytes["a"]?["s"] == nil)
    }

    @Test func aHolderOverlappingItselfCountsOnce() {
        #expect(DiskUsage.measure([(.vm("a"), extents(0..<100, 50..<150))]).totalBytes == 150)
    }

    @Test func theSameOffsetOnAnotherVolumeIsAnotherBlock() {
        let usage = DiskUsage.measure([(.vm("a"), extents(0..<100, device: 1)), (.vm("b"), extents(0..<100, device: 2))])
        #expect(usage.totalBytes == 200)
    }

    @Test func unmappedBytesCountAsUnshared() {
        let usage = DiskUsage.measure([
            (.vm("a"), extents(0..<100, unmapped: 40)),
            (.snapshot(vm: "a", tag: "s"), extents(unmapped: 7)),
        ])
        #expect(usage.totalBytes == 147)
        #expect(usage.uniqueBytes["a"]?["s"] == 7)
    }

    @Test func nothingMeasuresAsZero() {
        #expect(DiskUsage.measure([]) == DiskUsage())
    }

    // MARK: Real clones on the temporary directory's volume

    private let megabyte = 1 << 20

    private func temporaryStore() -> VMStore {
        let temp = FileManager.default.temporaryDirectory
        return VMStore(
            directory: temp.appending(path: "hobo-usage-\(UUID().uuidString)"),
            home: HoboHome(root: temp.appending(path: "hobo-home-\(UUID().uuidString)")),
            launchd: FakeLaunchctl().launchd
        )
    }

    private func made(_ name: String, in store: VMStore, megabytes: Int) throws -> URL {
        let bundle = try store.beginCreate(name)
        try store.finishCreate(name, config: Self.config, recipe: Data("cpus = 4\n".utf8))
        if megabytes > 0 { try write(megabytes, to: bundle.appending(path: "disk")) }
        return bundle
    }

    /// Into `file` at `offset`, or as a new file without one. Random, so nothing compresses it, and
    /// flushed, so its blocks are allocated.
    private func write(_ megabytes: Int, to file: URL, at offset: UInt64? = nil) throws {
        if offset == nil { #expect(FileManager.default.createFile(atPath: file.path, contents: nil)) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset ?? 0)
        var data = Data(count: megabytes * megabyte)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func clone(_ from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(copyfile(from.path, to.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0)
    }

    private func snapshot(_ tag: String, of bundle: URL) throws {
        let directory = Snapshot.directory(tag, in: bundle)
        try clone(bundle.appending(path: "disk"), to: directory.appending(path: "disk"))
        try SnapshotRecord(config: Self.config, createdAt: .now).write(to: directory.appending(path: Snapshot.recordFile))
    }

    /// Small files (`config.json` and the like) make figures a little over the data they're checked
    /// against, so a figure need only land in the same megabyte.
    private func expect(_ bytes: UInt64?, megabytes: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = Int(bytes ?? 0)
        #expect(abs(actual - megabytes * megabyte) < megabyte / 2, "\(actual) bytes", sourceLocation: sourceLocation)
    }

    private static let config = VMConfig(
        engine: .vz, os: .macOS, cpus: 4, memory: 8 << 30, disk: 80 << 30, macAddress: "5a:00:00:00:00:01",
        guestOSVersion: "27.2.0 (26B123)", created: Date(timeIntervalSince1970: 1_800_000_000),
        recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
    )

    @Test func clonesThatDivergedAreCountedExactly() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let a = try made("a", in: store, megabytes: 16)
        let b = try made("b", in: store, megabytes: 0)
        let c = try made("c", in: store, megabytes: 0)
        try clone(a.appending(path: "disk"), to: b.appending(path: "disk"))
        try clone(a.appending(path: "disk"), to: c.appending(path: "disk"))
        try write(2, to: b.appending(path: "disk"), at: 0)
        try write(1, to: c.appending(path: "disk"), at: 8 << 20)
        let vms = store.list()
        expect(store.diskUsage(of: vms).totalBytes, megabytes: 19)
        #expect(vms.allSatisfy { $0.allocatedBytes >= UInt64(16 * megabyte) })

        // Deleting the source frees nothing here: b still holds what c replaced, and c what b did.
        try store.delete("a")
        expect(store.diskUsage(of: store.list()).totalBytes, megabytes: 19)
    }

    @Test func snapshotsGrowAsTheVMDiverges() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try made("dev", in: store, megabytes: 16)
        try snapshot("old", of: bundle)
        var usage = store.diskUsage(of: store.list())
        expect(usage.totalBytes, megabytes: 16)
        expect(usage.snapshotBytes["dev"], megabytes: 0)

        try write(4, to: bundle.appending(path: "disk"), at: 0)
        try snapshot("new", of: bundle)
        try write(2, to: bundle.appending(path: "disk"), at: 8 << 20)
        let vms = store.list()
        usage = store.diskUsage(of: vms)
        expect(usage.totalBytes, megabytes: 22)
        expect(usage.snapshotBytes["dev"], megabytes: 6) // 4 only in old, 2 in old and new.
        expect(usage.totalSnapshotBytes, megabytes: 6)
        let snapshots = usage.snapshots(of: try #require(vms.first))
        #expect(snapshots.map(\.tag).sorted() == ["new", "old"])
        expect(snapshots.first { $0.tag == "old" }?.uniqueBytes, megabytes: 4)
        expect(snapshots.first { $0.tag == "new" }?.uniqueBytes, megabytes: 0)
    }

    @Test func whatAFailedSaveLeftBehindCountsButIsNotListed() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try made("dev", in: store, megabytes: 1)
        let partial = Snapshot.root(in: bundle).appending(path: ".saving-x")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try write(2, to: partial.appending(path: "disk"))
        let vms = store.list()
        let listing = VMListing(vms, usage: store.diskUsage(of: vms))
        #expect(listing.snapshotCount == 0)
        expect(listing.vms.first?.snapshotBytes, megabytes: 2)
        expect(listing.totalBytes, megabytes: 3)
    }

    @Test func aFileJustWrittenIsCounted() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try made("dev", in: store, megabytes: 0)
        var data = Data(count: 2 * megabyte)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try data.write(to: bundle.appending(path: "disk"))
        expect(store.diskUsage(of: store.list()).totalBytes, megabytes: 2)
    }

    /// VM disks are sparse: only the data counts, whatever the file's length.
    @Test func aSparseFilesHolesDoNotCount() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try made("dev", in: store, megabytes: 1)
        let disk = bundle.appending(path: "disk")
        try write(1, to: disk, at: 64 << 20)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 128 << 20) // So it ends in a hole too.
        try handle.close()
        expect(store.diskUsage(of: store.list()).totalBytes, megabytes: 2)
    }

    @Test func aStrayFileInSnapshotsCounts() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try made("dev", in: store, megabytes: 0)
        let root = Snapshot.root(in: bundle)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(2, to: root.appending(path: "stray"))
        let usage = store.diskUsage(of: store.list())
        expect(usage.snapshotBytes["dev"], megabytes: 2)
        expect(usage.uniqueBytes["dev"]?["stray"], megabytes: 2)
    }

    @Test func aFileThatCannotBeReadCountsAsUnmapped() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let file = try made("dev", in: store, megabytes: 2).appending(path: "disk")
        #expect(chmod(file.path, 0) == 0)
        var extents = FileExtents()
        extents.add(file: file)
        #expect(extents.mapped.isEmpty)
        expect(extents.unmappedBytes, megabytes: 2)
    }

    /// A symlink's target is someone else's to count, and a file can vanish while a VM runs.
    @Test func onlyRegularFilesAddExtents() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try made("dev", in: store, megabytes: 2)
        let link = bundle.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle.appending(path: "disk"))
        var extents = FileExtents()
        for file in [link, bundle, bundle.appending(path: "gone")] { extents.add(file: file) }
        #expect(extents == FileExtents())
    }

    @Test func listingJSONHasTotalsAndSnapshots() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let bundle = try made("dev", in: store, megabytes: 1)
        try snapshot("clean", of: bundle)
        let vms = store.list()
        let text = String(decoding: try HoboJSON.line(VMListing(vms, usage: store.diskUsage(of: vms))), as: UTF8.self)
        for key in [#""vms":["#, #""totalBytes":"#, #""snapshotCount":1"#, #""totalSnapshotBytes":"#, #""snapshotBytes":"#, #""tag":"clean""#, #""uniqueBytes":"#] {
            #expect(text.contains(key), "\(key) in \(text)")
        }
    }
}
