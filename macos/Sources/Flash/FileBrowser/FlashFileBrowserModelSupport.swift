import Foundation

/// Bounds follow-up directory scans when a busy tool continuously modifies
/// the visible folder. The monitor already coalesces its first event for 500
/// ms; this policy gives repeated scans roughly an 80% quiet period, with a
/// five-second cap so changes still converge in exceptionally large folders.
struct FlashFileBrowserExternalReloadPolicy {
    static let minimumDelay: TimeInterval = 0.5
    static let maximumDelay: TimeInterval = 5

    static func delayNanoseconds(
        afterLoadDuration duration: TimeInterval
    ) -> UInt64 {
        guard duration.isFinite, duration > 0 else { return 0 }

        let delay = min(
            maximumDelay,
            max(minimumDelay, duration * 4)
        )
        return UInt64((delay * 1_000_000_000).rounded())
    }
}

enum FlashFileBrowserModelError: LocalizedError, Equatable {
    case workingDirectoryUnavailable
    case itemIsNotFolder
    case itemUnavailable
    case nothingToPaste

    var errorDescription: String? {
        switch self {
        case .workingDirectoryUnavailable:
            "The session working directory is not available yet."
        case .itemIsNotFolder:
            "Only folders inside the session working directory can be browsed."
        case .itemUnavailable:
            "That file is no longer available in the session working directory."
        case .nothingToPaste:
            "The clipboard does not contain files to paste."
        }
    }
}

/// The immutable result of reconciling one directory enumeration with the
/// source rows currently published by ``FlashFileBrowserModel``.
struct FlashFileBrowserSnapshotReconciliation: Sendable {
    let presentedItems: [FlashFileBrowserItem]
    let shouldPublish: Bool
    let containsTransientTarget: Bool
}

/// Pure source-snapshot reconciliation shared by the model and focused tests.
///
/// Equality remains exact rather than relying on a hash or timestamp. A file
/// replaced at the same path must publish its new filesystem identity so stale
/// selection and mutation requests are rejected by the rest of the browser.
enum FlashFileBrowserSnapshotReconciler {
    static func reconcile(
        loadedItems: [FlashFileBrowserItem],
        currentItems: [FlashFileBrowserItem],
        showingHiddenFiles: Bool,
        transientTarget: URL?
    ) -> FlashFileBrowserSnapshotReconciliation {
        let targetPath = transientTarget.map {
            FlashFileBrowserPathPolicy.standardized($0).path
        }
        let presentedItems: [FlashFileBrowserItem]

        if showingHiddenFiles || targetPath == nil {
            presentedItems = loadedItems
        } else {
            presentedItems = loadedItems.filter { item in
                !item.isHidden || normalizedPath(of: item) == targetPath
            }
        }

        return .init(
            presentedItems: presentedItems,
            shouldPublish: currentItems != presentedItems,
            containsTransientTarget: targetPath.map { targetPath in
                presentedItems.contains {
                    normalizedPath(of: $0) == targetPath
                }
            } ?? false
        )
    }

    private static func normalizedPath(
        of item: FlashFileBrowserItem
    ) -> String {
        FlashFileBrowserPathPolicy.standardized(item.url).path
    }
}

/// Serial executor for source-snapshot reconciliation. Directory enumerations
/// can contain tens of thousands of rows, so both filtering and the exact
/// unchanged-snapshot comparison stay off the main actor.
actor FlashFileBrowserSnapshotWorker {
    func reconcile(
        loadedItems: [FlashFileBrowserItem],
        currentItems: [FlashFileBrowserItem],
        showingHiddenFiles: Bool,
        transientTarget: URL?
    ) -> FlashFileBrowserSnapshotReconciliation {
        FlashFileBrowserSnapshotReconciler.reconcile(
            loadedItems: loadedItems,
            currentItems: currentItems,
            showingHiddenFiles: showingHiddenFiles,
            transientTarget: transientTarget
        )
    }
}
