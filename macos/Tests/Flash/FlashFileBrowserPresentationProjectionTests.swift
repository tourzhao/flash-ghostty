import Foundation
import Testing
@testable import Ghostty

@Suite
struct FileBrowserProjectionTests {
    @Test
    func defaultDateOrderIsNewestFirstWithNaturalStableTies() {
        let newer = Date(timeIntervalSince1970: 200)
        let older = Date(timeIntervalSince1970: 100)
        let input = makeInput(items: [
            makeItem("file10.swift", inode: 1, modificationDate: newer),
            makeItem("unknown.swift", inode: 2),
            makeItem("older.swift", inode: 3, modificationDate: older),
            makeItem("file2.swift", inode: 4, modificationDate: newer),
        ])

        let result = FlashFileBrowserPresentationProjector.project(input)

        #expect(result.snapshot.items.map(\.name) == [
            "file2.swift",
            "file10.swift",
            "older.swift",
            "unknown.swift",
        ])
    }

    @Test
    func nameOrderUsesFinderStyleNumericComparisonInBothDirections() {
        let items = [
            makeItem("file10", inode: 1),
            makeItem("file2", inode: 2),
            makeItem("file1", inode: 3),
        ]
        let ascending = FlashFileBrowserPresentationProjector.project(
            makeInput(
                items: items,
                sort: .init(field: .name, direction: .ascending)
            )
        )
        let descending = FlashFileBrowserPresentationProjector.project(
            makeInput(
                items: items,
                sort: .init(field: .name, direction: .descending)
            )
        )

        #expect(ascending.snapshot.items.map(\.name) == ["file1", "file2", "file10"])
        #expect(descending.snapshot.items.map(\.name) == ["file10", "file2", "file1"])
    }

    @Test
    func filterSearchRevealAndAvailableTypesShareOneProjection() {
        let folder = makeItem("Sources", inode: 1, isDirectory: true)
        let source = makeItem("file2.swift", inode: 2)
        let otherSource = makeItem("file10.swift", inode: 3)
        let revealed = makeItem("README.md", inode: 4)
        let selectedType = FlashFileBrowserFileType(fileExtension: "swift")
        let input = makeInput(
            items: [revealed, otherSource, folder, source],
            query: "file",
            selectedTypes: [selectedType],
            revealedItemID: revealed.id,
            sort: .init(field: .name, direction: .ascending)
        )

        let result = FlashFileBrowserPresentationProjector.project(input)

        #expect(result.sourceVisitCount == input.items.count)
        #expect(result.snapshot.items.map(\.name) == [
            "file2.swift",
            "file10.swift",
            "README.md",
        ])
        #expect(result.snapshot.availableFileTypes == [
            FlashFileBrowserFileType(fileExtension: "md"),
            selectedType,
        ])
    }

    @Test
    func dismissingRevealResumesTheUnchangedQueryAndTypeSelection() {
        let selectedType = FlashFileBrowserFileType(fileExtension: "swift")
        let source = makeItem("source.swift", inode: 1)
        let target = makeItem("README.md", inode: 2)
        var input = makeInput(
            items: [source, target],
            query: "source",
            selectedTypes: [selectedType],
            revealedItemID: target.id,
            sort: .init(field: .name, direction: .ascending)
        )

        let revealed = FlashFileBrowserPresentationProjector.project(input)
        #expect(revealed.snapshot.items == [target, source])
        #expect(input.query == "source")
        #expect(input.selectedTypes == [selectedType])

        input.revealedItemID = nil
        let resumed = FlashFileBrowserPresentationProjector.project(input)
        #expect(resumed.snapshot.items == [source])
        #expect(input.query == "source")
        #expect(input.selectedTypes == [selectedType])
    }

    @Test
    func staleGenerationCannotCommitAfterANewerRequestBegins() {
        var generation = FlashFileBrowserProjectionGeneration()
        let staleRequest = generation.beginRequest()
        let currentRequest = generation.beginRequest()

        #expect(!generation.accepts(staleRequest))
        #expect(generation.accepts(currentRequest))
    }

    @Test
    func selectionUsesTheRowIndexWithoutDuplicatingItemStorage() {
        let first = makeItem("first.swift", inode: 1)
        let second = makeItem("second.swift", inode: 2)
        let projection = FlashFileBrowserPresentationProjector.project(
            makeInput(
                items: [second, first],
                sort: .init(field: .name, direction: .ascending)
            )
        )

        #expect(
            projection.snapshot.resolveSelection([second.id, first.id]) ==
                [first, second]
        )
        #expect(
            projection.snapshot.reconciledSelection([first.id, "stale-id"]) ==
                [first.id]
        )
        #expect(projection.snapshot.reconciledSelection(["stale-id"]).isEmpty)
        #expect(projection.snapshot.resolveSelection(["stale-id"]) == nil)
        #expect(projection.snapshot.resolveSelection([]) == nil)
    }

    @Test
    func tenThousandItemProjectionResolvesEachTypeOnceAndBuildsSelectionIndex() {
        let items = (0..<10_000).map { index in
            makeItem(
                "file\(index).\(index.isMultiple(of: 2) ? "swift" : "txt")",
                inode: UInt64(index + 1),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let input = makeInput(
            items: items,
            query: "file",
            selectedTypes: [FlashFileBrowserFileType(fileExtension: "swift")]
        )

        var fileTypeResolutionCount = 0
        let result = FlashFileBrowserPresentationProjector.project(
            input,
            fileTypeResolver: { item in
                fileTypeResolutionCount += 1
                return FlashFileBrowserTypeFilter.fileType(for: item)
            }
        )

        #expect(result.sourceVisitCount == 10_000)
        #expect(fileTypeResolutionCount == 10_000)
        #expect(result.snapshot.items.count == 5_000)
        #expect(result.snapshot.rowByItemID.count == 5_000)
        #expect(result.snapshot.items.first?.name == "file9998.swift")
        #expect(result.snapshot.items.last?.name == "file0.swift")
        if let first = result.snapshot.items.first {
            #expect(result.snapshot.rowByItemID[first.id] == 0)
        }
    }

    @Test
    func tenThousandItemNameSortIndexesATypeFilteredRevealOverride() throws {
        let itemCount = 10_000
        let targetIndex = 4_321
        let selectedTypes: Set<FlashFileBrowserFileType> = [
            FlashFileBrowserFileType(fileExtension: "swift"),
        ]
        let items = (0..<itemCount).reversed().map { index in
            makeItem(
                "file\(index).\(index == targetIndex ? "md" : "swift")",
                inode: UInt64(index + 1)
            )
        }
        let target = try #require(items.first { $0.name == "file\(targetIndex).md" })
        #expect(!FlashFileBrowserTypeFilter.isVisible(
            target,
            query: "",
            selectedTypes: selectedTypes
        ))

        let result = FlashFileBrowserPresentationProjector.project(
            makeInput(
                items: items,
                selectedTypes: selectedTypes,
                revealedItemID: target.id,
                sort: .init(field: .name, direction: .ascending)
            )
        )

        #expect(result.sourceVisitCount == itemCount)
        #expect(result.snapshot.items.count == itemCount)
        #expect(result.snapshot.items.first?.name == "file0.swift")
        #expect(result.snapshot.items.last?.name == "file9999.swift")
        #expect(result.snapshot.rowByItemID[target.id] == targetIndex)
        #expect(result.snapshot.items[targetIndex] == target)
    }

    @Test
    func tableComparatorsMapToPresentationSortState() {
        #expect(
            FlashFileBrowserListOrdering.presentationSort(
                from: FlashFileBrowserListOrdering.defaultSortOrder
            ) == .defaultOrder
        )
        #expect(
            FlashFileBrowserListOrdering.presentationSort(
                from: [KeyPathComparator(\.displayName, order: .forward)]
            ) == .init(field: .name, direction: .ascending)
        )
        #expect(
            FlashFileBrowserListOrdering.presentationSort(
                from: [KeyPathComparator(\.displayName, order: .reverse)]
            ) == .init(field: .name, direction: .descending)
        )
    }

    private func makeInput(
        items: [FlashFileBrowserItem],
        query: String = "",
        selectedTypes: Set<FlashFileBrowserFileType> = [],
        revealedItemID: FlashFileBrowserItem.ID? = nil,
        sort: FlashFileBrowserPresentationSort = .defaultOrder
    ) -> FlashFileBrowserPresentationInput {
        .init(
            items: items,
            directoryPath: "/tmp",
            query: query,
            selectedTypes: selectedTypes,
            revealedItemID: revealedItemID,
            sort: sort
        )
    }

    private func makeItem(
        _ name: String,
        inode: UInt64,
        isDirectory: Bool = false,
        modificationDate: Date? = nil
    ) -> FlashFileBrowserItem {
        FlashFileBrowserItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            identity: .init(device: 1, inode: inode),
            name: name,
            isDirectory: isDirectory,
            isPackage: false,
            isSymbolicLink: false,
            isHidden: false,
            modificationDate: modificationDate
        )
    }
}

private actor AsyncProjectionProbe {
    private let projectionStarts: AsyncStream<Void>
    private let projectionStartContinuation: AsyncStream<Void>.Continuation
    private let projectionFinishes: AsyncStream<Void>
    private let projectionFinishContinuation: AsyncStream<Void>.Continuation
    private var releaseFirstWasRequested = false
    private var releaseFirstContinuation: CheckedContinuation<Void, Never>?
    private var activeProjectionCount = 0
    private var maximumActiveProjectionCount = 0
    private var queries: [String] = []
    private var firstItemNames: [String?] = []

    init() {
        let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        projectionStarts = starts.stream
        projectionStartContinuation = starts.continuation
        let finishes = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        projectionFinishes = finishes.stream
        projectionFinishContinuation = finishes.continuation
    }

    var startedQueries: [String] {
        queries
    }

    var maximumConcurrentProjectionCount: Int {
        maximumActiveProjectionCount
    }

    var startedFirstItemNames: [String?] {
        firstItemNames
    }

    func waitForProjectionStart() async -> Bool {
        await waitForNextEvent(in: projectionStarts)
    }

    func waitForProjectionFinish() async -> Bool {
        await waitForNextEvent(in: projectionFinishes)
    }

    func releaseFirstProjection() {
        guard let releaseFirstContinuation else {
            releaseFirstWasRequested = true
            return
        }
        self.releaseFirstContinuation = nil
        releaseFirstContinuation.resume()
    }

    func project(
        _ input: FlashFileBrowserPresentationInput
    ) async -> FlashFileBrowserPresentationProjection {
        activeProjectionCount += 1
        maximumActiveProjectionCount = max(
            maximumActiveProjectionCount,
            activeProjectionCount
        )
        queries.append(input.query)
        firstItemNames.append(input.items.first?.name)
        let isFirstProjection = queries.count == 1
        projectionStartContinuation.yield()
        defer {
            activeProjectionCount -= 1
            projectionFinishContinuation.yield()
        }

        if isFirstProjection {
            await withTaskCancellationHandler {
                await waitForFirstRelease()
            } onCancel: {
                Task { await self.releaseFirstProjection() }
            }
        }
        return .init(
            snapshot: .empty,
            sourceVisitCount: input.items.count
        )
    }

    private func waitForFirstRelease() async {
        if releaseFirstWasRequested {
            releaseFirstWasRequested = false
            return
        }
        await withCheckedContinuation { continuation in
            precondition(releaseFirstContinuation == nil)
            releaseFirstContinuation = continuation
        }
    }

    private func waitForNextEvent(
        in events: AsyncStream<Void>
    ) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(5))
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

@Suite @MainActor
struct FileBrowserPresentationStoreTests {
    @Test
    func largeSourceChurnKeepsOnlyTheLatestPendingProjection() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Churn")
        let probe = AsyncProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            worker: .init { await probe.project($0) }
        )

        store.setSource(
            items: makeItems(
                prefix: "refresh-0",
                count: 10_000,
                identityOffset: 0,
                directory: directory
            ),
            directory: directory
        )
        let firstStarted = await probe.waitForProjectionStart()
        #expect(firstStarted)

        for refresh in 1...8 {
            store.setSource(
                items: makeItems(
                    prefix: "refresh-\(refresh)",
                    count: 10_000,
                    identityOffset: refresh * 10_000,
                    directory: directory
                ),
                directory: directory
            )
        }

        #expect(store.projectionStartCount == 1)
        #expect(store.pendingProjectionCount == 1)

        await probe.releaseFirstProjection()
        let latestStarted = await probe.waitForProjectionStart()
        #expect(latestStarted)
        let startedFirstItemNames = await probe.startedFirstItemNames
        #expect(startedFirstItemNames == [
            "refresh-0-0",
            "refresh-8-0",
        ])
        let maximumConcurrentProjectionCount = await probe
            .maximumConcurrentProjectionCount
        #expect(maximumConcurrentProjectionCount == 1)
        #expect(store.projectionStartCount == 2)
        #expect(store.pendingProjectionCount == 0)
    }

    @Test
    func cancelledDebouncesOnlyProjectTheLatestQuery() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Debounce")
        let probe = AsyncProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            searchDebounceDuration: .zero,
            worker: .init { await probe.project($0) }
        )

        store.setSource(
            items: makeItems(
                prefix: "debounce",
                count: 10_000,
                identityOffset: 0,
                directory: directory
            ),
            directory: directory
        )
        let firstStarted = await probe.waitForProjectionStart()
        #expect(firstStarted)

        for queryIndex in 0..<100 {
            store.setSearchQuery("query-\(queryIndex)")
        }
        let latestBecamePending = await waitForPendingProjection(in: store)
        #expect(latestBecamePending)
        #expect(store.projectionStartCount == 1)

        await probe.releaseFirstProjection()
        let latestStarted = await probe.waitForProjectionStart()
        #expect(latestStarted)
        let startedQueries = await probe.startedQueries
        #expect(startedQueries == ["", "query-99"])
        let maximumConcurrentProjectionCount = await probe
            .maximumConcurrentProjectionCount
        #expect(maximumConcurrentProjectionCount == 1)
        #expect(store.projectionStartCount == 2)
    }

    @Test
    func cancellingAPendingRevealDropsItWithoutStartingAnotherProjection() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Cancel")
        let probe = AsyncProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            worker: .init { await probe.project($0) }
        )
        let blockingItem = makeItem(
            "blocking.swift",
            inode: 1,
            directory: directory
        )
        store.setSource(items: [blockingItem], directory: directory)
        let firstStarted = await probe.waitForProjectionStart()
        #expect(firstStarted)

        let revealTarget = makeItem(
            "reveal.swift",
            inode: 2,
            directory: directory
        )
        let revealTask = Task { @MainActor in
            await store.presentRevealedItem(
                revealTarget.id,
                items: [revealTarget],
                directory: directory
            )
        }
        let revealBecamePending = await waitForPendingProjection(in: store)
        #expect(revealBecamePending)

        revealTask.cancel()
        let revealResult = await revealTask.value
        #expect(revealResult == nil)
        #expect(store.pendingProjectionCount == 0)

        await probe.releaseFirstProjection()
        let firstFinished = await probe.waitForProjectionFinish()
        #expect(firstFinished)
        await Task.yield()
        let startedFirstItemNames = await probe.startedFirstItemNames
        #expect(startedFirstItemNames == ["blocking.swift"])
        #expect(store.projectionStartCount == 1)
    }

    @Test
    func newerSourceSupersedesAPendingRevealAndResumesItsCaller() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Supersede")
        let probe = AsyncProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            worker: .init { await probe.project($0) }
        )
        let blockingItem = makeItem(
            "blocking.swift",
            inode: 1,
            directory: directory
        )
        store.setSource(items: [blockingItem], directory: directory)
        let firstStarted = await probe.waitForProjectionStart()
        #expect(firstStarted)

        let revealTarget = makeItem(
            "reveal.swift",
            inode: 2,
            directory: directory
        )
        let revealTask = Task { @MainActor in
            await store.presentRevealedItem(
                revealTarget.id,
                items: [revealTarget],
                directory: directory
            )
        }
        let revealBecamePending = await waitForPendingProjection(in: store)
        #expect(revealBecamePending)

        let latestItem = makeItem(
            "latest.swift",
            inode: 3,
            directory: directory
        )
        store.setSource(items: [latestItem], directory: directory)
        let revealResult = await revealTask.value
        #expect(revealResult == nil)
        #expect(store.pendingProjectionCount == 1)

        await probe.releaseFirstProjection()
        let latestStarted = await probe.waitForProjectionStart()
        #expect(latestStarted)
        let startedFirstItemNames = await probe.startedFirstItemNames
        #expect(startedFirstItemNames == [
            "blocking.swift",
            "latest.swift",
        ])
        #expect(store.projectionStartCount == 2)
    }

    @Test
    func revealUsesExplicitSourceAndDelayedDirectoryCallbackCannotEraseIt() async {
        let directory = URL(fileURLWithPath: "/tmp/Reveal")
        let target = FlashFileBrowserItem(
            url: directory.appendingPathComponent("target.swift"),
            identity: .init(device: 1, inode: 1),
            name: "target.swift",
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            isHidden: false,
            modificationDate: nil
        )
        let store = FlashFileBrowserPresentationStore()

        let snapshot = await store.presentRevealedItem(
            target.id,
            items: [target],
            directory: directory
        )

        #expect(snapshot?.items == [target])
        #expect(store.snapshot.items == [target])
        let projectionCount = store.projectionStartCount

        // Simulates a delayed SwiftUI currentDirectory callback for the same
        // navigation event after reveal has already installed its source.
        store.setDirectory(directory)
        #expect(store.projectionStartCount == projectionCount)
        #expect(store.snapshot.items == [target])
    }

    @Test
    func directoryChangeClearsOldRowsSynchronously() async {
        let oldDirectory = URL(fileURLWithPath: "/tmp/Old")
        let item = FlashFileBrowserItem(
            url: oldDirectory.appendingPathComponent("old.swift"),
            identity: .init(device: 1, inode: 1),
            name: "old.swift",
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            isHidden: false,
            modificationDate: nil
        )
        let store = FlashFileBrowserPresentationStore()
        _ = await store.presentRevealedItem(
            item.id,
            items: [item],
            directory: oldDirectory
        )
        #expect(store.snapshotRevision == 1)

        store.setDirectory(URL(fileURLWithPath: "/tmp/New"))

        #expect(store.snapshot.items.isEmpty)
        #expect(store.snapshotRevision == 2)
    }

    private func waitForPendingProjection(
        in store: FlashFileBrowserPresentationStore
    ) async -> Bool {
        for _ in 0..<1_000 {
            if store.pendingProjectionCount == 1 { return true }
            await Task.yield()
        }
        return false
    }

    private func makeItems(
        prefix: String,
        count: Int,
        identityOffset: Int,
        directory: URL
    ) -> [FlashFileBrowserItem] {
        (0..<count).map { index in
            makeItem(
                "\(prefix)-\(index)",
                inode: UInt64(identityOffset + index + 1),
                directory: directory
            )
        }
    }

    private func makeItem(
        _ name: String,
        inode: UInt64,
        directory: URL
    ) -> FlashFileBrowserItem {
        FlashFileBrowserItem(
            url: directory.appendingPathComponent(name),
            identity: .init(device: 1, inode: inode),
            name: name,
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            isHidden: false,
            modificationDate: nil
        )
    }
}
