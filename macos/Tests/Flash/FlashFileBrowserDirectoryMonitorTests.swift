import Foundation
import Testing
@testable import Ghostty

@Suite @MainActor
struct FlashFileBrowserDirectoryMonitorTests {
    @Test
    func compatibilitySymlinkPathPreservesCallbackIdentity() async throws {
        // macOS exposes /tmp as a compatibility symlink to /private/tmp, while
        // FSEvents reports the canonical path. The monitor must filter with
        // that canonical path without leaking it into the model-facing URL.
        let root = try makeDirectory(
            named: "CompatibilitySymlink",
            baseDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        let monitor = FlashFileBrowserDirectoryMonitor(
            debounceNanoseconds: 80_000_000
        )
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        var callbacks: [URL] = []
        #expect(monitor.watch(root) { callbacks.append($0) })
        #expect(monitor.watchedDirectory == normalized(root))
        await allowSourceRegistration()

        try Data("canonical event path".utf8).write(
            to: root.appendingPathComponent("created.txt")
        )

        #expect(await waitUntil { callbacks.count == 1 })
        #expect(callbacks == [normalized(root)])
    }

    @Test
    func externalCreationDeliversNormalizedDirectoryOnMainActor() async throws {
        let root = try makeDirectory(named: "ExternalCreation")
        let monitor = FlashFileBrowserDirectoryMonitor(
            debounceNanoseconds: 80_000_000
        )
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        var callbacks: [URL] = []
        var callbackWasOnMainThread = false
        #expect(monitor.watch(root) { directory in
            callbacks.append(directory)
            callbackWasOnMainThread = Thread.isMainThread
        })
        await allowSourceRegistration()

        try Data("created externally".utf8).write(
            to: root.appendingPathComponent("created.txt")
        )

        #expect(await waitUntil { callbacks.count == 1 })
        #expect(callbacks == [normalized(root)])
        #expect(callbackWasOnMainThread)
    }

    @Test
    func inPlaceOverwriteOfExistingFileTriggersChange() async throws {
        let root = try makeDirectory(named: "InPlaceOverwrite")
        let file = root.appendingPathComponent("existing.txt")
        try Data("before".utf8).write(to: file)
        let monitor = FlashFileBrowserDirectoryMonitor(
            debounceNanoseconds: 120_000_000
        )
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        var callbacks: [URL] = []
        #expect(monitor.watch(root) { callbacks.append($0) })
        await allowSourceRegistration()

        try overwrite(file, with: Data("after, with a new mtime".utf8))

        // FSEvents may split one filesystem operation across batches. This
        // integration test verifies that in-place child changes are visible;
        // the injected burst test below owns exact debounce-window semantics.
        #expect(await waitUntil { !callbacks.isEmpty })
        #expect(callbacks.allSatisfy { $0 == normalized(root) })
    }

    @Test
    func switchingDirectoryInvalidatesPendingAndFutureOldEvents() async throws {
        let first = try makeDirectory(named: "First")
        let second = try makeDirectory(named: "Second")
        let monitor = FlashFileBrowserDirectoryMonitor(
            debounceNanoseconds: 250_000_000,
            ignoresFileSystemEventsForTesting: true
        )
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        var callbacks: [URL] = []
        #expect(monitor.watch(first) { callbacks.append($0) })
        let oldEvent = try #require(
            monitor.currentEventIdentityForTesting
        )

        // Queue an event inside the old debounce window, then replace the
        // watch before it can be delivered.
        monitor.receiveEventForTesting(oldEvent)
        #expect(monitor.hasPendingDeliveryForTesting)

        #expect(monitor.watch(second) { callbacks.append($0) })
        let currentEvent = try #require(
            monitor.currentEventIdentityForTesting
        )

        // A callback already queued by the replaced FSEvents registration must
        // also be rejected by its captured generation.
        monitor.receiveEventForTesting(oldEvent)
        #expect(!monitor.hasPendingDeliveryForTesting)

        await pause(nanoseconds: 350_000_000)
        #expect(callbacks.isEmpty)

        monitor.receiveEventForTesting(currentEvent)
        #expect(await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            callbacks.count == 1
        })
        #expect(callbacks == [normalized(second)])
    }

    @Test
    func samePathReplacementRebindsToNewDirectoryIdentity() async throws {
        let root = try makeDirectory(named: "Replaced")
        let oldRoot = root.deletingLastPathComponent().appendingPathComponent(
            "\(root.lastPathComponent)-old"
        )
        let monitor = FlashFileBrowserDirectoryMonitor(
            debounceNanoseconds: 80_000_000
        )
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: oldRoot)
        }

        var callbackCount = 0
        #expect(monitor.watch(root) { _ in callbackCount += 1 })
        await allowSourceRegistration()

        try FileManager.default.moveItem(at: root, to: oldRoot)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        #expect(await waitUntil { callbackCount == 1 })

        // The second event belongs to the newly-created vnode at the same
        // path. Receiving it proves the monitor did not remain on oldRoot.
        try Data("new identity".utf8).write(
            to: root.appendingPathComponent("new.txt")
        )
        #expect(await waitUntil { callbackCount == 2 })
    }

    @Test
    func stopInvalidatesPendingAndFutureEvents() async throws {
        let root = try makeDirectory(named: "Stop")
        let monitor = FlashFileBrowserDirectoryMonitor(
            // Keep the delivery comfortably beyond the test timeout. The
            // aggregate suite can delay a 40-ms sleep long enough for a short
            // debounce to fire before `stop()`, which tests scheduler load
            // rather than invalidation semantics.
            debounceNanoseconds: 5_000_000_000
        )
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        var callbackCount = 0
        #expect(monitor.watch(root) { _ in callbackCount += 1 })
        await allowSourceRegistration()

        monitor.receiveEventForTesting()
        #expect(monitor.hasPendingDeliveryForTesting)
        #expect(callbackCount == 0)
        monitor.stop()
        #expect(!monitor.hasPendingDeliveryForTesting)
        // Repeated stop calls must remain harmless and must not close a reused
        // descriptor or resurrect the prior callback.
        monitor.stop()
        try Data().write(to: root.appendingPathComponent("after-stop.txt"))

        await pause(nanoseconds: 350_000_000)
        #expect(callbackCount == 0)
        #expect(monitor.watchedDirectory == nil)
    }

    @Test
    func burstOfDirectoryEventsIsCoalescedIntoOneFixedWindow() async throws {
        let root = try makeDirectory(named: "Burst")
        let monitor = FlashFileBrowserDirectoryMonitor()
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        var callbackCount = 0
        #expect(monitor.watch(root) { _ in callbackCount += 1 })
        await allowSourceRegistration()

        for _ in 0..<12 {
            monitor.receiveEventForTesting()
        }

        #expect(await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            callbackCount == 1
        })
        await pause(nanoseconds: 350_000_000)
        #expect(callbackCount == 1)
    }
}

private extension FlashFileBrowserDirectoryMonitorTests {
    func makeDirectory(
        named name: String,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let directory = baseDirectory
            .appendingPathComponent(
                "FlashFileBrowserDirectoryMonitorTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func normalized(_ directory: URL) -> URL {
        URL(
            fileURLWithPath: directory.standardizedFileURL.path,
            isDirectory: true
        )
    }

    func overwrite(_ file: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
    }

    func allowSourceRegistration() async {
        await pause(nanoseconds: 100_000_000)
    }

    func pause(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return true }
            await pause(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
