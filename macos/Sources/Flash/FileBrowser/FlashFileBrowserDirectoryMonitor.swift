import CoreServices
import Darwin
import Foundation

/// Watches the one directory currently presented by the file browser.
///
/// The protocol keeps filesystem observation injectable so model tests can
/// drive external changes without depending on kernel event timing.
@MainActor
protocol FlashFileBrowserDirectoryMonitoring: AnyObject {
    typealias ChangeHandler = @MainActor (URL) -> Void

    /// Replaces the current watch. Returns false when an event stream cannot
    /// be started for `directory`.
    @discardableResult
    func watch(
        _ directory: URL,
        onChange: @escaping ChangeHandler
    ) -> Bool

    /// Stops watching and invalidates both queued and future callbacks.
    func stop()
}

/// A single FSEvents monitor for the file browser's visible directory.
///
/// File-level events are required here: a vnode source attached to the
/// directory does not report an existing child's in-place content or mtime
/// change. The stream is recursive by API, so its callback filters ordinary
/// events to the directory itself and its immediate children before reaching
/// the main actor. The first relevant event starts a fixed debounce window;
/// later events in that window share one callback and do not postpone it.
/// Filesystem enumeration remains the model's job. A 500-ms window caps
/// continuous build churn at two enumerations per second.
@MainActor
final class FlashFileBrowserDirectoryMonitor:
    FlashFileBrowserDirectoryMonitoring {
    nonisolated static let defaultDebounceNanoseconds: UInt64 = 500_000_000

    private let debounceNanoseconds: UInt64
    private var registration: Registration?
    private var debounceTask: Task<Void, Never>?
    private var changeHandler: ChangeHandler?
    private var pendingRebind = false
    private var generation: UInt = 0

#if DEBUG
    private let ignoresFileSystemEventsForTesting: Bool
#endif

    private(set) var watchedDirectory: URL?

#if DEBUG
    struct EventIdentityForTesting {
        fileprivate let directory: URL
        fileprivate let generation: UInt
    }

    /// Test-only visibility into the debounce boundary. Kernel event delivery
    /// is intentionally asynchronous, so tests must observe that an event is
    /// actually pending before asserting that `stop()` invalidates it.
    var hasPendingDeliveryForTesting: Bool {
        debounceTask != nil
    }

    /// Captures the same directory and generation identity retained by an
    /// FSEvents callback. Tests use this to deliver an explicitly stale event
    /// after replacing a watch, without depending on kernel batching latency.
    var currentEventIdentityForTesting: EventIdentityForTesting? {
        guard let watchedDirectory, registration != nil else { return nil }
        return EventIdentityForTesting(
            directory: watchedDirectory,
            generation: generation
        )
    }

    /// Drives the debounce state machine without coupling its unit tests to
    /// FSEvents batching latency. Separate integration tests still exercise
    /// real file creation, overwrite, replacement, and canonical-path events.
    func receiveEventForTesting(
        _ identity: EventIdentityForTesting? = nil,
        requiresRebind: Bool = false
    ) {
        guard let identity = identity ?? currentEventIdentityForTesting else {
            return
        }
        receiveEvent(
            for: identity.directory,
            generation: identity.generation,
            requiresRebind: requiresRebind
        )
    }
#endif

    init(
        debounceNanoseconds: UInt64 =
            FlashFileBrowserDirectoryMonitor.defaultDebounceNanoseconds
    ) {
        self.debounceNanoseconds = debounceNanoseconds
#if DEBUG
        self.ignoresFileSystemEventsForTesting = false
#endif
    }

#if DEBUG
    init(
        debounceNanoseconds: UInt64,
        ignoresFileSystemEventsForTesting: Bool
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.ignoresFileSystemEventsForTesting =
            ignoresFileSystemEventsForTesting
    }
#endif

    @discardableResult
    func watch(
        _ directory: URL,
        onChange: @escaping ChangeHandler
    ) -> Bool {
        guard directory.isFileURL else {
            stop()
            return false
        }

        let normalizedDirectory = normalized(directory)

        // Updating the callback for an unchanged live watch should not create
        // a blind spot by needlessly stopping and recreating the stream.
        if watchedDirectory == normalizedDirectory, registration != nil {
            changeHandler = onChange
            return true
        }

        invalidateCurrentWatch()

        generation &+= 1
        let watchGeneration = generation
        guard let registration = makeRegistration(
            for: normalizedDirectory,
            generation: watchGeneration
        ) else { return false }

        watchedDirectory = normalizedDirectory
        changeHandler = onChange
        self.registration = registration

        return true
    }

    func stop() {
        invalidateCurrentWatch()
    }

    private func receiveEvent(
        for directory: URL,
        generation eventGeneration: UInt,
        requiresRebind: Bool
    ) {
        guard eventGeneration == generation,
              directory == watchedDirectory,
              registration != nil else { return }

        if requiresRebind {
            // WatchRoot reports that the lexical directory path was renamed,
            // removed, or replaced. Attach a fresh stream at delivery time,
            // after atomic-save/recreate bursts have had time to settle.
            pendingRebind = true
            registration?.cancel()
            registration = nil
        }

        // Fixed-window debounce: once scheduled, later events are coalesced
        // without moving the delivery deadline.
        guard debounceTask == nil else { return }

        let delay = debounceNanoseconds
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self else { return }
            self.debounceTask = nil
            guard eventGeneration == self.generation,
                  directory == self.watchedDirectory else { return }

            if self.pendingRebind {
                self.pendingRebind = false
                _ = self.reopenCurrentWatch(
                    directory,
                    generation: eventGeneration
                )
            }

            self.changeHandler?(directory)
        }
    }

    @discardableResult
    private func reopenCurrentWatch(
        _ directory: URL,
        generation watchGeneration: UInt
    ) -> Bool {
        guard let registration = makeRegistration(
            for: directory,
            generation: watchGeneration
        ) else { return false }
        self.registration = registration
        return true
    }

    private func makeRegistration(
        for directory: URL,
        generation watchGeneration: UInt
    ) -> Registration? {
        // FSEvents reports the filesystem's canonical path even when its
        // watched path used a macOS compatibility symlink such as `/var`.
        // Foundation's `resolvingSymlinksInPath` intentionally preserves that
        // spelling, so derive the kernel path from an opened directory instead.
        // Keep `directory` for the callback because the model compares it with
        // its lexical current-directory URL.
        guard let observedDirectoryPath = observedDirectoryPath(
            for: directory
        ) else { return nil }

        return Registration(
            directoryPath: observedDirectoryPath
        ) { [weak self] requiresRebind in
            Task { @MainActor [weak self] in
#if DEBUG
                if self?.ignoresFileSystemEventsForTesting == true { return }
#endif
                self?.receiveEvent(
                    for: directory,
                    generation: watchGeneration,
                    requiresRebind: requiresRebind
                )
            }
        }
    }

    private func observedDirectoryPath(for directory: URL) -> String? {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = pathBuffer.withUnsafeMutableBufferPointer {
            Darwin.fcntl(descriptor, F_GETPATH, $0.baseAddress!)
        }
        guard result == 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private func invalidateCurrentWatch() {
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingRebind = false
        changeHandler = nil
        watchedDirectory = nil

        registration?.cancel()
        registration = nil
    }

    private func normalized(_ directory: URL) -> URL {
        URL(
            fileURLWithPath: directory.standardizedFileURL.path,
            isDirectory: true
        )
    }
}

private extension FlashFileBrowserDirectoryMonitor {
    /// Owns one started FSEventStream. Repeated cancellation atomically takes
    /// the stream before stopping and releasing it, so `stop` and deinit are
    /// both safe.
    final class Registration: @unchecked Sendable {
        private final class EventContext: @unchecked Sendable {
            private static let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs |
                    kFSEventStreamEventFlagUserDropped |
                    kFSEventStreamEventFlagKernelDropped |
                    kFSEventStreamEventFlagEventIdsWrapped |
                    kFSEventStreamEventFlagMount |
                    kFSEventStreamEventFlagUnmount
            )

            private let directoryPath: String
            private let childPathPrefix: String
            private let eventHandler: @Sendable (Bool) -> Void

            init(
                directoryPath: String,
                eventHandler: @escaping @Sendable (Bool) -> Void
            ) {
                self.directoryPath = directoryPath
                self.childPathPrefix = directoryPath == "/"
                    ? "/"
                    : "\(directoryPath)/"
                self.eventHandler = eventHandler
            }

            func receive(
                paths: NSArray,
                flags: UnsafePointer<FSEventStreamEventFlags>,
                eventCount: Int
            ) {
                var hasRelevantEvent = false
                var requiresRebind = false

                for index in 0..<min(eventCount, paths.count) {
                    let eventFlags = flags[index]
                    if eventFlags & Self.rescanFlags != 0 {
                        hasRelevantEvent = true
                    }
                    if eventFlags & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagRootChanged
                    ) != 0 {
                        hasRelevantEvent = true
                        requiresRebind = true
                    }

                    guard let path = paths[index] as? String,
                          isDirectoryOrImmediateChild(path) else { continue }
                    hasRelevantEvent = true
                }

                if hasRelevantEvent {
                    eventHandler(requiresRebind)
                }
            }

            private func isDirectoryOrImmediateChild(_ path: String) -> Bool {
                if path == directoryPath { return true }
                guard path.hasPrefix(childPathPrefix) else { return false }

                let relativePath = path.dropFirst(childPathPrefix.count)
                return !relativePath.isEmpty && !relativePath.contains("/")
            }
        }

        private static let callback: FSEventStreamCallback = { _, context, eventCount, rawPaths, flags, _ in
            guard let context else { return }
            let eventContext = Unmanaged<EventContext>
                .fromOpaque(context)
                .takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            eventContext.receive(
                paths: paths,
                flags: flags,
                eventCount: eventCount
            )
        }

        private let callbackQueue = DispatchQueue(
            label: "com.flashghostty.file-browser.fsevents",
            qos: .utility
        )
        private let cancellationLock = NSLock()
        private var stream: FSEventStreamRef?

        init?(
            directoryPath: String,
            eventHandler: @escaping @Sendable (Bool) -> Void
        ) {
            let eventContext = EventContext(
                directoryPath: directoryPath,
                eventHandler: eventHandler
            )
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(eventContext).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    _ = Unmanaged<EventContext>.fromOpaque(pointer).retain()
                    return UnsafeRawPointer(pointer)
                },
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<EventContext>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
            let createFlags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes |
                    kFSEventStreamCreateFlagNoDefer |
                    kFSEventStreamCreateFlagWatchRoot |
                    kFSEventStreamCreateFlagFileEvents
            )
            guard let stream = FSEventStreamCreate(
                nil,
                Self.callback,
                &context,
                [directoryPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                createFlags
            ) else { return nil }

            FSEventStreamSetDispatchQueue(stream, callbackQueue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return nil
            }
            self.stream = stream
        }

        func cancel() {
            let stream = cancellationLock.withLock {
                let stream = self.stream
                self.stream = nil
                return stream
            }
            guard let stream else { return }

            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        deinit {
            cancel()
        }
    }
}
