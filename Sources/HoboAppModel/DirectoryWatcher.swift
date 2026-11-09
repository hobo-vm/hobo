import CoreServices
import Foundation

/// Calls `changed` on the main queue whenever anything under `directories` changes (FSEvents,
/// coalesced over `latency`). A directory that doesn't exist yet is created, since FSEvents can't
/// watch a path that isn't there.
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void

    public init(_ directories: [URL], latency: TimeInterval = 0.3, changed: @escaping () -> Void) {
        self.changed = changed
        for directory in directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, directories.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
