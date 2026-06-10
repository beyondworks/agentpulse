import Foundation
import CoreServices

/// Recursively watches directories via FSEvents and fires `onChange` (coalesced
/// by `latency`) whenever anything under them is written. Used to refresh usage
/// in real time instead of polling on a fixed interval.
public final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: () -> Void

    public init(paths: [String], latency: CFTimeInterval = 1.5, onChange: @escaping () -> Void) {
        self.paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.latency = latency
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          latency, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
