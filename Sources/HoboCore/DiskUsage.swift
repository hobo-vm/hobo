import Foundation

/// What VMs' files really occupy, found by comparing the physical blocks they lie on. Clones share
/// blocks, and once they diverge nothing else says with what (APFS's clone IDs match only while
/// files are identical, and a file's private size leaves out blocks shared by some but not all
/// clones), so every block is counted once, whichever clones hold it.
public struct DiskUsage: Equatable, Sendable {
    /// Bytes all the bundles occupy, each block once.
    public var totalBytes: UInt64 = 0
    /// Bytes held by some snapshot and by no VM's own files: `totalBytes` less the VMs' own blocks.
    public var totalSnapshotBytes: UInt64 = 0
    /// By VM name: bytes its snapshots hold that the VM's own files don't.
    public var snapshotBytes: [String: UInt64] = [:]
    /// By VM name, then tag: bytes only that snapshot holds, which deleting it alone would free.
    public var uniqueBytes: [String: [String: UInt64]] = [:]

    /// `vm`'s snapshots, oldest first, each with what it alone holds.
    public func snapshots(of vm: VMStore.VM) -> [Snapshot] {
        Snapshot.list(in: vm.bundle).map { snapshot in
            var snapshot = snapshot
            snapshot.uniqueBytes = uniqueBytes[vm.name]?[snapshot.tag] ?? 0
            return snapshot
        }
    }

    /// Who holds a block. Anything in `snapshots/` counts as a snapshot named after its entry there,
    /// so what a failed save left behind is counted too.
    enum Holder: Hashable {
        case vm(String)
        case snapshot(vm: String, tag: String)
    }

    /// Adds `bytes` held by exactly `holders`.
    mutating func count(_ bytes: UInt64, heldBy holders: some Collection<Holder>) {
        totalBytes += bytes
        var ownedByVM: Set<String> = []
        var inSnapshotOf: Set<String> = []
        for holder in holders {
            switch holder {
            case .vm(let name): ownedByVM.insert(name)
            case .snapshot(let name, _): inSnapshotOf.insert(name)
            }
        }
        if ownedByVM.isEmpty, !inSnapshotOf.isEmpty { totalSnapshotBytes += bytes }
        for name in inSnapshotOf.subtracting(ownedByVM) { snapshotBytes[name, default: 0] += bytes }
        if holders.count == 1, case .snapshot(let name, let tag) = holders.first {
            uniqueBytes[name, default: [:]][tag, default: 0] += bytes
        }
    }

    /// The usage of everything `holdings` holds: a sweep over the physical blocks in order, keeping
    /// track of who holds the stretch it's in. Blocks are compared only within a volume.
    static func measure(_ holdings: [(holder: Holder, extents: FileExtents)]) -> DiskUsage {
        var usage = DiskUsage()
        // A holder's own files may share blocks, hence a count of how many of its extents are open.
        struct Edge { var device: Int32, offset: Int64, change: Int, holder: Holder }
        var edges: [Edge] = []
        for (holder, extents) in holdings {
            if extents.unmappedBytes > 0 { usage.count(extents.unmappedBytes, heldBy: [holder]) }
            for extent in extents.extents {
                edges.append(Edge(device: extent.device, offset: extent.range.lowerBound, change: 1, holder: holder))
                edges.append(Edge(device: extent.device, offset: extent.range.upperBound, change: -1, holder: holder))
            }
        }
        edges.sort { ($0.device, $0.offset) < ($1.device, $1.offset) }
        var open: [Holder: Int] = [:]
        var previous: Edge?
        for edge in edges {
            if let previous, previous.device == edge.device, edge.offset > previous.offset, !open.isEmpty {
                usage.count(UInt64(edge.offset - previous.offset), heldBy: open.keys)
            }
            open[edge.holder, default: 0] += edge.change
            if open[edge.holder] == 0 { open[edge.holder] = nil }
            previous = edge
        }
        return usage
    }
}

/// Where some files' data lies on disk.
struct FileExtents: Equatable, Sendable {
    struct Extent: Equatable, Sendable {
        var device: Int32
        var range: Range<Int64>
    }

    var extents: [Extent] = []
    /// Bytes of files whose blocks can't be looked up, such as on a volume without the call. No
    /// clones are told apart there, so these count as unshared.
    var unmappedBytes: UInt64 = 0

    mutating func add(file: URL) {
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        if let found = Self.lookUp(file, device: info.st_dev) {
            extents += found
        } else {
            unmappedBytes += UInt64(info.st_blocks) * 512
        }
    }

    /// `file`'s extents, skipping its holes, or nil if they can't all be found.
    private static func lookUp(_ file: URL, device: Int32) -> [Extent]? {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var found: [Extent] = []
        var position: off_t = 0
        while true {
            let data = lseek(descriptor, position, SEEK_DATA)
            if data < 0 { return errno == ENXIO ? found : nil } // ENXIO: no more data.
            let hole = lseek(descriptor, data, SEEK_HOLE)
            guard hole > data else { return nil }
            var offset = data
            while offset < hole {
                var mapping = log2phys()
                mapping.l2p_contigbytes = hole - offset
                mapping.l2p_devoffset = offset
                guard fcntl(descriptor, F_LOG2PHYS_EXT, &mapping) == 0, mapping.l2p_contigbytes > 0, mapping.l2p_devoffset >= 0 else { return nil }
                let start = mapping.l2p_devoffset
                found.append(Extent(device: device, range: start..<(start + mapping.l2p_contigbytes)))
                offset += mapping.l2p_contigbytes
            }
            position = hole
        }
    }
}

extension VMStore {
    /// The disk usage of `vms`, which should be every VM (`list()`), since what a VM's snapshot
    /// alone holds depends on what the others share with it.
    public func diskUsage(of vms: [VM]) -> DiskUsage {
        DiskUsage.measure(vms.flatMap { vm -> [(holder: DiskUsage.Holder, extents: FileExtents)] in
            var own = FileExtents()
            for file in Self.files(in: vm.bundle, excluding: Snapshot.directoryName) { own.add(file: file) }
            let root = Snapshot.root(in: vm.bundle)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return [(.vm(vm.name), own)] + entries.map { entry in
                let item = root.appending(path: entry)
                var extents = FileExtents()
                extents.add(file: item)
                for file in Self.files(in: item) { extents.add(file: file) }
                return (.snapshot(vm: vm.name, tag: entry), extents)
            }
        })
    }

    /// Everything under `directory`, leaving out any top-level entry named `excluded`.
    private static func files(in directory: URL, excluding excluded: String? = nil) -> [URL] {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let file as URL in files {
            if files.level == 1, file.lastPathComponent == excluded {
                files.skipDescendants()
            } else {
                found.append(file)
            }
        }
        return found
    }
}
