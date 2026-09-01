import Combine
import Foundation

/// Sort state used by the presentation projection rather than by SwiftUI's
/// render path. Keeping this value Sendable lets a large directory be sorted
/// away from the main actor.
struct FlashFileBrowserPresentationSort: Equatable, Sendable {
    enum Field: Equatable, Sendable {
        case name
        case modificationDate
    }

    enum Direction: Equatable, Sendable {
        case ascending
        case descending
    }

    static let defaultOrder = Self(
        field: .modificationDate,
        direction: .descending
    )

    let field: Field
    let direction: Direction
}

struct FlashFileBrowserPresentationInput: Equatable, Sendable {
    var items: [FlashFileBrowserItem]
    var directoryPath: String?
    var query: String
    var selectedTypes: Set<FlashFileBrowserFileType>
    var revealedItemID: FlashFileBrowserItem.ID?
    var sort: FlashFileBrowserPresentationSort
}

/// An immutable projection consumed directly by the SwiftUI view. The row
/// lookup keeps selection work proportional to the selected rows instead of
/// rescanning a 10k-entry directory on every unrelated view update.
struct FlashFileBrowserPresentationSnapshot: Equatable, Sendable {
    static let empty = Self(
        items: [],
        availableFileTypes: [],
        rowByItemID: [:]
    )

    let items: [FlashFileBrowserItem]
    let availableFileTypes: [FlashFileBrowserFileType]
    let rowByItemID: [FlashFileBrowserItem.ID: Int]

    func reconciledSelection(
        _ selectedIDs: Set<FlashFileBrowserItem.ID>
    ) -> Set<FlashFileBrowserItem.ID> {
        Set(selectedIDs.lazy.filter { rowByItemID[$0] != nil })
    }

    func resolveSelection(
        _ selectedIDs: Set<FlashFileBrowserItem.ID>
    ) -> [FlashFileBrowserItem]? {
        guard !selectedIDs.isEmpty else { return nil }

        let locatedItems = selectedIDs.compactMap { id -> (Int, FlashFileBrowserItem)? in
            guard let row = rowByItemID[id], items.indices.contains(row) else {
                return nil
            }
            return (row, items[row])
        }
        guard locatedItems.count == selectedIDs.count else { return nil }
        return locatedItems.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

struct FlashFileBrowserPresentationProjection: Sendable {
    let snapshot: FlashFileBrowserPresentationSnapshot
    /// Testable evidence that filtering and type collection share one source
    /// traversal. Sorting naturally performs comparator calls afterwards.
    let sourceVisitCount: Int
}

/// Pure, Sendable projection suitable for detached execution and unit tests.
enum FlashFileBrowserPresentationProjector {
    static func project(
        _ input: FlashFileBrowserPresentationInput,
        fileTypeResolver: (FlashFileBrowserItem) -> FlashFileBrowserFileType? = {
            FlashFileBrowserTypeFilter.fileType(for: $0)
        }
    ) -> FlashFileBrowserPresentationProjection {
        var availableTypes = input.selectedTypes
        var visibleItems: [FlashFileBrowserItem] = []
        visibleItems.reserveCapacity(input.items.count)
        let normalizedQuery = FlashFileBrowserTypeFilter.normalizedQuery(input.query)
        var sourceVisitCount = 0

        for item in input.items {
            sourceVisitCount += 1
            let fileType = fileTypeResolver(item)
            if let fileType {
                availableTypes.insert(fileType)
            }
            if FlashFileBrowserTypeFilter.isVisible(
                item,
                normalizedQuery: normalizedQuery,
                selectedTypes: input.selectedTypes,
                resolvedFileType: fileType,
                revealing: input.revealedItemID
            ) {
                visibleItems.append(item)
            }
        }

        visibleItems.sort { lhs, rhs in
            isOrderedBefore(lhs, rhs, using: input.sort)
        }

        var rowByItemID: [FlashFileBrowserItem.ID: Int] = [:]
        rowByItemID.reserveCapacity(visibleItems.count)
        for (row, item) in visibleItems.enumerated() {
            rowByItemID[item.id] = row
        }

        return .init(
            snapshot: .init(
                items: visibleItems,
                availableFileTypes: availableTypes.sorted(),
                rowByItemID: rowByItemID
            ),
            sourceVisitCount: sourceVisitCount
        )
    }

    private static func isOrderedBefore(
        _ lhs: FlashFileBrowserItem,
        _ rhs: FlashFileBrowserItem,
        using sort: FlashFileBrowserPresentationSort
    ) -> Bool {
        let primaryOrder: ComparisonResult
        switch sort.field {
        case .name:
            primaryOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
        case .modificationDate:
            primaryOrder = lhs.listModificationDateSortValue.compare(
                rhs.listModificationDateSortValue
            )
        }

        if primaryOrder != .orderedSame {
            switch sort.direction {
            case .ascending:
                return primaryOrder == .orderedAscending
            case .descending:
                return primaryOrder == .orderedDescending
            }
        }

        // Date ties retain Finder-style natural name ordering. Exact name
        // ties use the stable filesystem identity so refreshes cannot shuffle.
        let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}

/// Monotonic commit gate shared by immediate and debounced requests. Results
/// from an older worker request can never replace a newer projection.
struct FlashFileBrowserProjectionGeneration: Sendable {
    private(set) var current: UInt = 0

    mutating func beginRequest() -> UInt {
        current &+= 1
        return current
    }

    func accepts(_ generation: UInt) -> Bool {
        generation == current
    }
}

/// Runs CPU-bound projections away from the main actor. The presentation store
/// is the sole caller and never submits more than one projection at a time;
/// actor isolation is the execution boundary, not the request-coalescing
/// mechanism.
actor FlashFileBrowserPresentationWorker {
    typealias Projector = @Sendable (
        FlashFileBrowserPresentationInput
    ) async -> FlashFileBrowserPresentationProjection

    private let projector: Projector

    init(
        projector: @escaping Projector = {
            FlashFileBrowserPresentationProjector.project($0)
        }
    ) {
        self.projector = projector
    }

    fileprivate func project(
        _ input: FlashFileBrowserPresentationInput
    ) async -> FlashFileBrowserPresentationProjection? {
        guard !Task.isCancelled else { return nil }
        let projection = await projector(input)
        guard !Task.isCancelled else { return nil }
        return projection
    }
}

/// Owns the presentation pipeline independently of filesystem state. Search
/// typing is debounced; directory, type, reveal, and sort changes are projected
/// immediately. All expensive work runs outside the main actor.
@MainActor
final class FlashFileBrowserPresentationStore: ObservableObject {
    /// Keep the 10k-row payload out of SwiftUI's change-comparison path. Views
    /// observe the scalar revision and read this immutable snapshot on demand.
    private(set) var snapshot = FlashFileBrowserPresentationSnapshot.empty {
        didSet { snapshotRevision &+= 1 }
    }
    @Published private(set) var snapshotRevision: UInt = 0
    private(set) var projectionStartCount = 0
    /// Diagnostic evidence for the one-replaceable-pending invariant.
    var pendingProjectionCount: Int { pendingProjection == nil ? 0 : 1 }

    private var input: FlashFileBrowserPresentationInput
    private var generation = FlashFileBrowserProjectionGeneration()
    private var debounceTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var runningProjectionGeneration: UInt?
    private var pendingProjection: ProjectionTicket?
    private let searchDebounceDuration: Duration
    private let worker: FlashFileBrowserPresentationWorker

    init(
        selectedTypes: Set<FlashFileBrowserFileType> = [],
        searchDebounceDuration: Duration = .milliseconds(150),
        worker: FlashFileBrowserPresentationWorker = .init()
    ) {
        input = .init(
            items: [],
            directoryPath: nil,
            query: "",
            selectedTypes: selectedTypes,
            revealedItemID: nil,
            sort: .defaultOrder
        )
        self.searchDebounceDuration = searchDebounceDuration
        self.worker = worker
    }

    deinit {
        debounceTask?.cancel()
        projectionTask?.cancel()
        pendingProjection?.completion?(nil)
    }

    func setSource(items: [FlashFileBrowserItem], directory: URL?) {
        let directoryPath = normalizedDirectoryPath(directory)
        if input.directoryPath != directoryPath {
            input.revealedItemID = nil
            clearSnapshotIfNeeded()
        }
        input.items = items
        input.directoryPath = directoryPath
        scheduleImmediateProjection()
    }

    /// Invalidates rows synchronously when navigation changes directory. A
    /// delayed SwiftUI callback for a directory already installed by reveal is
    /// a no-op, so it cannot erase that reveal's newer explicit source.
    func setDirectory(_ directory: URL?) {
        let directoryPath = normalizedDirectoryPath(directory)
        guard input.directoryPath != directoryPath else { return }
        input.directoryPath = directoryPath
        input.items = []
        input.revealedItemID = nil
        clearSnapshotIfNeeded()
        scheduleImmediateProjection()
    }

    func setSearchQuery(_ query: String) {
        guard input.query != query || input.revealedItemID != nil else { return }
        input.query = query
        input.revealedItemID = nil
        scheduleDebouncedProjection()
    }

    func setSelectedTypes(_ selectedTypes: Set<FlashFileBrowserFileType>) {
        guard input.selectedTypes != selectedTypes || input.revealedItemID != nil else { return }
        input.selectedTypes = selectedTypes
        input.revealedItemID = nil
        scheduleImmediateProjection()
    }

    func setSort(_ sort: FlashFileBrowserPresentationSort) {
        guard input.sort != sort else { return }
        input.sort = sort
        scheduleImmediateProjection()
    }

    func setRevealedItemID(_ itemID: FlashFileBrowserItem.ID?) {
        guard input.revealedItemID != itemID else { return }
        input.revealedItemID = itemID
        scheduleImmediateProjection()
    }

    /// Projects and commits a reveal before the caller resolves its scroll row.
    /// A concurrent source/filter change invalidates this result and returns nil.
    func presentRevealedItem(
        _ itemID: FlashFileBrowserItem.ID,
        items: [FlashFileBrowserItem],
        directory: URL?
    ) async -> FlashFileBrowserPresentationSnapshot? {
        let directoryPath = normalizedDirectoryPath(directory)
        if input.directoryPath != directoryPath {
            clearSnapshotIfNeeded()
        }
        input.items = items
        input.directoryPath = directoryPath
        input.revealedItemID = itemID
        let requestGeneration = beginRequest()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueProjection(
                    .init(
                        generation: requestGeneration,
                        completion: { snapshot in
                            continuation.resume(returning: snapshot)
                        }
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(generation: requestGeneration)
            }
        }
    }

    private func normalizedDirectoryPath(_ directory: URL?) -> String? {
        directory.map { FlashFileBrowserPathPolicy.standardized($0).path }
    }

    private func clearSnapshotIfNeeded() {
        guard snapshot != .empty else { return }
        snapshot = .empty
    }

    private func scheduleImmediateProjection() {
        enqueueProjection(.init(generation: beginRequest()))
    }

    private func scheduleDebouncedProjection() {
        let requestGeneration = beginRequest()
        let debounceDuration = searchDebounceDuration
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.generation.accepts(requestGeneration) else { return }
            self.debounceTask = nil
            self.enqueueProjection(.init(generation: requestGeneration))
        }
    }

    /// Invalidates any request that has not started yet. The running projection
    /// is deliberately left alone because Swift's synchronous sort cannot be
    /// preempted; once it finishes, its generation gate rejects the stale
    /// result and the single latest pending request starts.
    private func beginRequest() -> UInt {
        debounceTask?.cancel()
        debounceTask = nil
        if let pendingProjection {
            self.pendingProjection = nil
            pendingProjection.completion?(nil)
        }
        return generation.beginRequest()
    }

    /// Keeps at most one running projection and one replaceable pending ticket.
    /// The pending ticket contains no item array; `input` remains the sole
    /// latest snapshot until that ticket is promoted to running work.
    private func enqueueProjection(_ ticket: ProjectionTicket) {
        guard projectionTask == nil else {
            if let pendingProjection {
                pendingProjection.completion?(nil)
            }
            pendingProjection = ticket
            return
        }
        startProjection(ticket)
    }

    private func startProjection(_ ticket: ProjectionTicket) {
        precondition(projectionTask == nil)
        projectionStartCount += 1
        let requestInput = input
        let worker = worker
        runningProjectionGeneration = ticket.generation
        projectionTask = Task { @MainActor [weak self] in
            let projection = await worker.project(requestInput)
            guard let self else {
                ticket.completion?(nil)
                return
            }

            self.projectionTask = nil
            self.runningProjectionGeneration = nil

            let acceptedSnapshot: FlashFileBrowserPresentationSnapshot?
            if !Task.isCancelled,
               let projection,
               self.generation.accepts(ticket.generation) {
                self.snapshot = projection.snapshot
                acceptedSnapshot = projection.snapshot
            } else {
                acceptedSnapshot = nil
            }
            ticket.completion?(acceptedSnapshot)
            self.startPendingProjectionIfNeeded()
        }
    }

    private func startPendingProjectionIfNeeded() {
        guard let pendingProjection else { return }
        self.pendingProjection = nil
        guard generation.accepts(pendingProjection.generation) else {
            pendingProjection.completion?(nil)
            return
        }
        startProjection(pendingProjection)
    }

    private func cancelRequest(generation requestGeneration: UInt) {
        guard generation.accepts(requestGeneration) else { return }

        if pendingProjection?.generation == requestGeneration {
            let cancelledProjection = pendingProjection
            pendingProjection = nil
            _ = generation.beginRequest()
            cancelledProjection?.completion?(nil)
            return
        }

        guard runningProjectionGeneration == requestGeneration else { return }
        _ = generation.beginRequest()
        projectionTask?.cancel()
    }

    private struct ProjectionTicket: Sendable {
        let generation: UInt
        let completion: (@Sendable (
            FlashFileBrowserPresentationSnapshot?
        ) -> Void)?

        init(
            generation: UInt,
            completion: (@Sendable (
                FlashFileBrowserPresentationSnapshot?
            ) -> Void)? = nil
        ) {
            self.generation = generation
            self.completion = completion
        }
    }
}
