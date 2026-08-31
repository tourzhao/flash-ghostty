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

private final class BlockingProjectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let projectionStarted = DispatchSemaphore(value: 0)
    private let projectionFinished = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private var activeProjectionCount = 0
    private var maximumActiveProjectionCount = 0
    private var queries: [String] = []
    private var firstItemNames: [String?] = []

    var startedQueries: [String] {
        lock.withLock { queries }
    }

    var maximumConcurrentProjectionCount: Int {
        lock.withLock { maximumActiveProjectionCount }
    }

    var startedFirstItemNames: [String?] {
        lock.withLock { firstItemNames }
    }

    func waitForProjectionStart() -> Bool {
        projectionStarted.wait(timeout: .now() + 5) == .success
    }

    func waitForProjectionFinish() -> Bool {
        projectionFinished.wait(timeout: .now() + 5) == .success
    }

    func releaseFirstProjection() {
        releaseFirst.signal()
    }

    func project(
        _ input: FlashFileBrowserPresentationInput
    ) -> FlashFileBrowserPresentationProjection {
        let isFirstProjection = lock.withLock {
            activeProjectionCount += 1
            maximumActiveProjectionCount = max(
                maximumActiveProjectionCount,
                activeProjectionCount
            )
            queries.append(input.query)
            firstItemNames.append(input.items.first?.name)
            return queries.count == 1
        }
        projectionStarted.signal()
        defer {
            lock.withLock {
                activeProjectionCount -= 1
            }
            projectionFinished.signal()
        }

        if isFirstProjection {
            _ = releaseFirst.wait(timeout: .now() + 30)
        }
        return .init(
            snapshot: .empty,
            sourceVisitCount: input.items.count
        )
    }
}

@Suite @MainActor
struct FileBrowserPresentationStoreTests {
    @Test
    func largeSourceChurnKeepsOnlyTheLatestPendingProjection() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Churn")
        let probe = BlockingProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            worker: .init { probe.project($0) }
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
        let firstStarted = await Task.detached {
            probe.waitForProjectionStart()
        }.value
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

        probe.releaseFirstProjection()
        let latestStarted = await Task.detached {
            probe.waitForProjectionStart()
        }.value
        #expect(latestStarted)
        #expect(probe.startedFirstItemNames == [
            "refresh-0-0",
            "refresh-8-0",
        ])
        #expect(probe.maximumConcurrentProjectionCount == 1)
        #expect(store.projectionStartCount == 2)
        #expect(store.pendingProjectionCount == 0)
    }

    @Test
    func cancelledDebouncesOnlyProjectTheLatestQuery() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Debounce")
        let probe = BlockingProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            searchDebounceDuration: .zero,
            worker: .init { probe.project($0) }
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
        let firstStarted = await Task.detached {
            probe.waitForProjectionStart()
        }.value
        #expect(firstStarted)

        for queryIndex in 0..<100 {
            store.setSearchQuery("query-\(queryIndex)")
        }
        let latestBecamePending = await waitForPendingProjection(in: store)
        #expect(latestBecamePending)
        #expect(store.projectionStartCount == 1)

        probe.releaseFirstProjection()
        let latestStarted = await Task.detached {
            probe.waitForProjectionStart()
        }.value
        #expect(latestStarted)
        #expect(probe.startedQueries == ["", "query-99"])
        #expect(probe.maximumConcurrentProjectionCount == 1)
        #expect(store.projectionStartCount == 2)
    }

    @Test
    func cancellingAPendingRevealDropsItWithoutStartingAnotherProjection() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Cancel")
        let probe = BlockingProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            worker: .init { probe.project($0) }
        )
        let blockingItem = makeItem(
            "blocking.swift",
            inode: 1,
            directory: directory
        )
        store.setSource(items: [blockingItem], directory: directory)
        let firstStarted = await Task.detached {
            probe.waitForProjectionStart()
        }.value
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

        probe.releaseFirstProjection()
        let firstFinished = await Task.detached {
            probe.waitForProjectionFinish()
        }.value
        #expect(firstFinished)
        await Task.yield()
        #expect(probe.startedFirstItemNames == ["blocking.swift"])
        #expect(store.projectionStartCount == 1)
    }

    @Test
    func newerSourceSupersedesAPendingRevealAndResumesItsCaller() async {
        let directory = URL(fileURLWithPath: "/tmp/Projection-Supersede")
        let probe = BlockingProjectionProbe()
        let store = FlashFileBrowserPresentationStore(
            worker: .init { probe.project($0) }
        )
        let blockingItem = makeItem(
            "blocking.swift",
            inode: 1,
            directory: directory
        )
        store.setSource(items: [blockingItem], directory: directory)
        let firstStarted = await Task.detached {
            probe.waitForProjectionStart()
        }.value
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

        probe.releaseFirstProjection()
        let latestStarted = await Task.detached {
            probe.waitForProjectionStart()
        }.value
        #expect(latestStarted)
        #expect(probe.startedFirstItemNames == [
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
