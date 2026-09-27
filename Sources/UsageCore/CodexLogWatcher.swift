import Foundation
import CoreServices

/// macOS delivers filesystem changes without a polling loop or a network request.
/// The callback runs on the main queue. Call start/stop from one owner.
public final class CodexLogWatcher {
    private final class Callback {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    private let root: URL
    private let callback: Callback
    private var stream: FSEventStreamRef?

    public init(root: URL? = nil, onChange: @escaping () -> Void) {
        self.root = root ?? CodexSource.home.appendingPathComponent("sessions")
        callback = Callback(onChange)
    }

    @discardableResult
    public func start() -> Bool {
        if stream != nil { return true }
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().action()
            },
            &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
