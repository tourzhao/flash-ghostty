import Foundation
import Testing
@testable import Ghostty

@Suite
struct FileBrowserReloadPolicyTests {
    @Test
    func invalidAndZeroDurationsDoNotDelay() {
        #expect(
            FlashFileBrowserExternalReloadPolicy
                .delayNanoseconds(afterLoadDuration: 0) == 0
        )
        #expect(
            FlashFileBrowserExternalReloadPolicy
                .delayNanoseconds(afterLoadDuration: .infinity) == 0
        )
    }

    @Test
    func delayIsProportionalAndBounded() {
        #expect(
            FlashFileBrowserExternalReloadPolicy
                .delayNanoseconds(afterLoadDuration: 0.001) == 500_000_000
        )
        #expect(
            FlashFileBrowserExternalReloadPolicy
                .delayNanoseconds(afterLoadDuration: 0.4) == 1_600_000_000
        )
        #expect(
            FlashFileBrowserExternalReloadPolicy
                .delayNanoseconds(afterLoadDuration: 5) == 5_000_000_000
        )
    }
}

@Suite @MainActor
struct FlashFileBrowserModelTests {
    typealias SessionID = SessionWorkspace.SessionID

    @Test
    func largeItemPayloadPublishesOnlyItsScalarRevision() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let items = (0..<10_000).map { index in
            makeItem("item-\(index).txt", in: root)
        }
        await fileSystem.setListing(items, for: root)
        let model = FlashFileBrowserModel(fileSystem: fileSystem)

        #expect(model.itemsRevision == 0)
        await model.synchronize(sessionID: SessionID(), directory: root)

        #expect(model.items.count == items.count)
        #expect(model.itemsRevision == 1)

        // An identical reload is reconciled off-main and does not publish a
        // new revision or force SwiftUI to compare the 10k-element payload.
        await model.reload()
        #expect(model.itemsRevision == 1)
    }

    @Test
    func navigatingBetweenEmptyDirectoriesDoesNotPublishAnItemRevision() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let child = root.appendingPathComponent("Empty Child", isDirectory: true)
        await fileSystem.setListing([], for: root)
        await fileSystem.setListing([], for: child)
        let model = FlashFileBrowserModel(fileSystem: fileSystem)

        await model.synchronize(sessionID: SessionID(), directory: root)
        #expect(model.itemsRevision == 0)

        await model.navigate(to: child)

        #expect(
            model.currentDirectory ==
                FlashFileBrowserPathPolicy.standardized(child)
        )
        #expect(model.items.isEmpty)
        #expect(model.itemsRevision == 0)
    }

    @Test
    func togglingHiddenFilesWithoutAHiddenItemDoesNotPublishAnItemRevision() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let visible = makeItem("visible.txt", in: root)
        await fileSystem.setListing([visible], for: root, showingHiddenFiles: false)
        await fileSystem.setListing([visible], for: root, showingHiddenFiles: true)
        let model = FlashFileBrowserModel(fileSystem: fileSystem)

        await model.synchronize(sessionID: SessionID(), directory: root)
        #expect(model.itemsRevision == 1)

        await model.setShowingHiddenFiles(true)
        await model.setShowingHiddenFiles(false)

        #expect(model.items == [visible])
        #expect(model.itemsRevision == 1)
    }

    @Test
    func differentSessionWithoutDirectoryClearsPreviousSession() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let originalItem = makeItem("original.txt", in: root)
        await fileSystem.setListing([originalItem], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        #expect(model.items == [originalItem])

        await model.synchronize(sessionID: SessionID(), directory: nil)

        #expect(model.sessionRoot == nil)
        #expect(model.currentDirectory == nil)
        #expect(model.items.isEmpty)
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
        #expect(!model.isLoading)
    }

    @Test
    func sameSessionTemporaryNilPreservesLastUsableDirectory() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let sessionID = SessionID()
        let root = makeRoot()
        let child = root.appendingPathComponent("Child")
            .standardizedFileURL
        let childItem = makeItem("Child", in: root, isDirectory: true)
        let nestedItem = makeItem("nested.txt", in: child)
        await fileSystem.setListing([childItem], for: root)
        await fileSystem.setListing([nestedItem], for: child)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: sessionID, directory: root)
        await model.navigate(to: childItem)
        let loadCount = await fileSystem.recordedLoadRequests.count

        await model.synchronize(sessionID: sessionID, directory: nil)

        #expect(model.sessionRoot == root)
        #expect(model.currentDirectory == child)
        #expect(model.items == [nestedItem])
        #expect(model.canGoBack)
        #expect(await fileSystem.recordedLoadRequests.count == loadCount)
    }

    @Test
    func workingDirectoryChangeWithinSessionResetsNavigation() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let sessionID = SessionID()
        let firstRoot = makeRoot()
        let firstChild = firstRoot.appendingPathComponent("Child")
            .standardizedFileURL
        let firstChildItem = makeItem("Child", in: firstRoot, isDirectory: true)
        let secondRoot = makeRoot()
        let secondItem = makeItem("second.txt", in: secondRoot)
        await fileSystem.setListing([firstChildItem], for: firstRoot)
        await fileSystem.setListing([], for: firstChild)
        await fileSystem.setListing([secondItem], for: secondRoot)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: sessionID, directory: firstRoot)
        await model.navigate(to: firstChildItem)
        #expect(model.canGoBack)

        await model.synchronize(sessionID: sessionID, directory: secondRoot)

        #expect(model.sessionRoot == secondRoot)
        #expect(model.currentDirectory == secondRoot)
        #expect(model.items == [secondItem])
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
    }

    @Test
    func backForwardAndRootMaintainDeterministicHistory() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let child = root.appendingPathComponent("Child")
            .standardizedFileURL
        let childItem = makeItem("Child", in: root, isDirectory: true)
        let nestedItem = makeItem("nested.txt", in: child)
        await fileSystem.setListing([childItem], for: root)
        await fileSystem.setListing([nestedItem], for: child)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await model.navigate(to: childItem)
        #expect(model.currentDirectory == child)
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        await model.goBack()
        #expect(model.currentDirectory == root)
        #expect(!model.canGoBack)
        #expect(model.canGoForward)

        await model.goForward()
        #expect(model.currentDirectory == child)
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        await model.goToRoot()
        #expect(model.currentDirectory == root)
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        await model.goBack()
        #expect(model.currentDirectory == child)
        #expect(model.canGoForward)
    }

    @Test
    func revealNestedFileNavigatesToParentAndReturnsCurrentRow() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let child = root.appendingPathComponent("Child").standardizedFileURL
        let childItem = makeItem("Child", in: root, isDirectory: true)
        let target = makeItem("target.swift", in: child)
        await fileSystem.setListing([childItem], for: root)
        await fileSystem.setListing([target], for: child)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)

        let revealed = await model.reveal(target.url)

        #expect(revealed == target)
        #expect(model.currentDirectory == child)
        #expect(model.items == [target])
        #expect(model.canGoBack)
        #expect(!model.canGoForward)
    }

    @Test
    func revealCurrentDirectoryFileRefreshesWithoutAddingHistory() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let target = makeItem("target.swift", in: root)
        await fileSystem.setListing([target], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let revealed = await model.reveal(target.url)

        #expect(revealed == target)
        #expect(model.currentDirectory == root)
        #expect(!model.canGoBack)
        #expect(await fileSystem.recordedLoadRequests.count == 2)
    }

    @Test
    func revealRejectsTargetOutsideRootWithoutNavigating() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let existing = makeItem("existing.swift", in: root)
        let outside = makeRoot().appendingPathComponent("outside.swift")
        await fileSystem.setListing([existing], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let revealed = await model.reveal(outside)

        #expect(revealed == nil)
        #expect(model.currentDirectory == root)
        #expect(model.items == [existing])
        #expect(!model.canGoBack)
        #expect(await fileSystem.recordedLoadRequests.count == 1)
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.outsideWorkingDirectory.localizedDescription
        )
    }

    @Test
    func revealMissingFileDoesNotSelectAnotherRow() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let existing = makeItem("existing.swift", in: root)
        let missing = root.appendingPathComponent("missing.swift")
        await fileSystem.setListing([existing], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let revealed = await model.reveal(missing)

        #expect(revealed == nil)
        #expect(!model.showingHiddenFiles)
        #expect(
            model.errorMessage ==
                FlashFileBrowserModelError.itemUnavailable.localizedDescription
        )
    }

    @Test
    func revealDotfileTemporarilyShowsOnlyItsRowWithoutChangingPreference() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let visible = makeItem("visible.txt", in: root)
        let target = makeItem(".env", in: root, isHidden: true)
        let otherHidden = makeItem(".secret", in: root, isHidden: true)
        await fileSystem.setListing([visible], for: root, showingHiddenFiles: false)
        await fileSystem.setListing(
            [visible, target, otherHidden],
            for: root,
            showingHiddenFiles: true
        )

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let revealed = await model.reveal(target.url)

        #expect(revealed == target)
        #expect(!model.showingHiddenFiles)
        #expect(model.items == [visible, target])
        #expect(await fileSystem.recordedLoadRequests.last?.showingHiddenFiles == true)

        model.dismissReveal()
        #expect(model.items == [visible])
        await model.reload()
        #expect(await fileSystem.recordedLoadRequests.last?.showingHiddenFiles == false)
    }

    @Test
    func revealFinderHiddenFileWithoutDotPrefixKeepsHiddenPreference() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let target = makeItem("FinderHidden", in: root, isHidden: true)
        await fileSystem.setListing([], for: root, showingHiddenFiles: false)
        await fileSystem.setListing([target], for: root, showingHiddenFiles: true)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let revealed = await model.reveal(target.url)

        #expect(revealed == target)
        #expect(!model.showingHiddenFiles)
        #expect(model.items == [target])
    }

    @Test
    func sameSessionRefreshRetainsTransientHiddenReveal() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let sessionID = SessionID()
        let root = makeRoot()
        let target = makeItem(".env", in: root, isHidden: true)
        await fileSystem.setListing([], for: root, showingHiddenFiles: false)
        await fileSystem.setListing([target], for: root, showingHiddenFiles: true)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: sessionID, directory: root)
        _ = await model.reveal(target.url)
        await model.synchronize(sessionID: sessionID, directory: root)

        #expect(!model.showingHiddenFiles)
        #expect(model.items == [target])
    }

    @Test
    func revealDirectorySelectsLexicalRowInsteadOfEnteringIt() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let parent = root.appendingPathComponent("Parent").standardizedFileURL
        let parentItem = makeItem("Parent", in: root, isDirectory: true)
        let target = makeItem(
            "Linked Folder",
            in: parent,
            isDirectory: true,
            isSymbolicLink: true
        )
        await fileSystem.setListing([parentItem], for: root)
        await fileSystem.setListing([target], for: parent)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let revealed = await model.reveal(target.url)

        #expect(revealed == target)
        #expect(revealed?.url == target.url)
        #expect(model.currentDirectory == parent)
        #expect(model.currentDirectory != target.url)
    }

    @Test
    func revealRootReturnsToRootWithoutSelectingAnOutsideParent() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let child = root.appendingPathComponent("Child").standardizedFileURL
        let childItem = makeItem("Child", in: root, isDirectory: true)
        await fileSystem.setListing([childItem], for: root)
        await fileSystem.setListing([], for: child)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await model.navigate(to: childItem)

        let revealed = await model.reveal(root)

        #expect(revealed == nil)
        #expect(model.currentDirectory == root)
        #expect(model.errorMessage == nil)
    }

    @Test
    func canceledRevealCannotChangeHiddenPreferenceOrOverrideNewRequest() async throws {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let staleTarget = makeItem(".stale", in: root, isHidden: true)
        let currentTarget = makeItem("current.swift", in: root)
        await fileSystem.setListing([currentTarget], for: root)
        await fileSystem.setListing(
            [staleTarget, currentTarget],
            for: root,
            showingHiddenFiles: true
        )

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        defer {
            Task {
                await fileSystem.resumeAllPendingLoads(returning: [])
            }
        }
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setSuspendingLoads(true)

        let staleTask = Task { await model.reveal(staleTarget.url) }
        try #require(await fileSystem.waitForLoadCount(2))
        let staleLoad = try #require(await fileSystem.recordedLoadRequests.last)

        staleTask.cancel()
        let currentTask = Task { await model.reveal(currentTarget.url) }
        try #require(await fileSystem.waitForLoadCount(3))
        let currentLoad = try #require(await fileSystem.recordedLoadRequests.last)

        #expect(await fileSystem.resumeLoad(staleLoad.id, returning: []))
        await Task.yield()
        #expect(await fileSystem.resumeLoad(
            currentLoad.id,
            returning: [currentTarget]
        ))

        #expect(await staleTask.value == nil)
        #expect(await currentTask.value == currentTarget)
        #expect(!model.showingHiddenFiles)
        #expect(model.items == [currentTarget])
        #expect(model.errorMessage == nil)
    }

    @Test
    func packagesRemainLaunchableItemsInsteadOfNavigableFolders() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let package = makeItem(
            "Example.app",
            in: root,
            isDirectory: true,
            isPackage: true
        )
        await fileSystem.setListing([package], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let loadCount = await fileSystem.recordedLoadRequests.count
        await model.navigate(to: package)

        #expect(model.currentDirectory == root)
        #expect(
            model.errorMessage ==
                FlashFileBrowserModelError.itemIsNotFolder.localizedDescription
        )
        #expect(await fileSystem.recordedLoadRequests.count == loadCount)
    }

    @Test
    func navigationRejectsResolvedSymlinkEscapeAndLexicalOutsidePath() async throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("FlashFileBrowserModelTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Root", isDirectory: true)
        let outside = container.appendingPathComponent("Outside", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: container) }

        let link = root.appendingPathComponent("Escaping Link", isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let linkItem = makeItem(
            "Escaping Link",
            in: root,
            isDirectory: true,
            isSymbolicLink: true
        )
        await fileSystem.setListing([linkItem], for: root)
        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)

        await model.navigate(to: linkItem)
        #expect(model.currentDirectory?.path == root.standardizedFileURL.path)
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.outsideWorkingDirectory.localizedDescription
        )

        model.clearError()
        await model.navigate(to: outside)
        #expect(model.currentDirectory?.path == root.standardizedFileURL.path)
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.outsideWorkingDirectory.localizedDescription
        )
    }

    @Test
    func reloadAndForwardRejectFolderRetargetedOutsideRoot() async throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("FlashFileBrowserModelTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Root", isDirectory: true)
        let inside = root.appendingPathComponent("Inside", isDirectory: true)
        let outside = container.appendingPathComponent("Outside", isDirectory: true)
        try fileManager.createDirectory(at: inside, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: container) }

        let link = root.appendingPathComponent("Linked Folder", isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: inside)

        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let linkItem = makeItem(
            "Linked Folder",
            in: root,
            isDirectory: true,
            isSymbolicLink: true
        )
        let nestedItem = makeItem("inside.txt", in: link)
        await fileSystem.setListing([linkItem], for: root)
        await fileSystem.setListing([nestedItem], for: link)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await model.navigate(to: linkItem)
        #expect(model.items == [nestedItem])

        try fileManager.removeItem(at: link)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

        await model.reload()
        #expect(model.items.isEmpty)
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.outsideWorkingDirectory.localizedDescription
        )

        await model.goBack()
        #expect(model.currentDirectory?.path == root.path)
        model.clearError()

        await model.goForward()
        #expect(model.currentDirectory?.path == root.path)
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.outsideWorkingDirectory.localizedDescription
        )
    }

    @Test
    func hiddenFileToggleReloadsWithTheRequestedVisibility() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let visible = makeItem("visible.txt", in: root)
        let hidden = makeItem(".hidden.txt", in: root, isHidden: true)
        await fileSystem.setListing([visible], for: root, showingHiddenFiles: false)
        await fileSystem.setListing(
            [hidden, visible],
            for: root,
            showingHiddenFiles: true
        )

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        #expect(model.items == [visible])
        #expect(model.itemsRevision == 1)

        await model.setShowingHiddenFiles(true)
        #expect(model.showingHiddenFiles)
        #expect(Set(model.items.map(\.id)) == Set([visible.id, hidden.id]))
        #expect(model.itemsRevision == 2)

        await model.setShowingHiddenFiles(false)
        #expect(!model.showingHiddenFiles)
        #expect(model.items == [visible])
        #expect(model.itemsRevision == 3)
        #expect(
            await fileSystem.recordedLoadRequests.map(\.showingHiddenFiles) ==
                [false, true, false]
        )

        await model.setShowingHiddenFiles(false)
        #expect(await fileSystem.recordedLoadRequests.count == 3)
        #expect(model.itemsRevision == 3)
    }

    @Test
    func directoryMonitorRefreshesAndTracksTheVisibleDirectory() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let monitor = ControlledDirectoryMonitor()
        let root = makeRoot()
        let child = root.appendingPathComponent("Child").standardizedFileURL
        let childItem = makeItem("Child", in: root, isDirectory: true)
        let createdAtRoot = makeItem("created.swift", in: root)
        let createdInChild = makeItem("nested.swift", in: child)
        await fileSystem.setListing([childItem], for: root)
        await fileSystem.setListing([], for: child)

        let model = FlashFileBrowserModel(
            fileSystem: fileSystem,
            directoryMonitor: monitor
        )
        model.setDirectoryMonitoringEnabled(true)
        await model.synchronize(sessionID: SessionID(), directory: root)
        #expect(monitor.watchedDirectory?.path == root.path)

        await fileSystem.setListing([childItem, createdAtRoot], for: root)
        monitor.emitChange(in: root)
        #expect(await waitUntil {
            model.items.contains(createdAtRoot)
        })

        await model.navigate(to: childItem)
        #expect(monitor.watchedDirectory?.path == child.path)
        let loadCountAfterNavigation = await fileSystem.recordedLoadRequests.count

        // A callback already queued by the old watch cannot refresh the newly
        // visible directory.
        monitor.emitChange(in: root)
        await Task.yield()
        #expect(await fileSystem.recordedLoadRequests.count == loadCountAfterNavigation)

        await fileSystem.setListing([createdInChild], for: child)
        monitor.emitChange(in: child)
        #expect(await waitUntil {
            model.items == [createdInChild]
        })

        model.setDirectoryMonitoringEnabled(false)
        let loadCountAfterStopping = await fileSystem.recordedLoadRequests.count
        #expect(monitor.watchedDirectory == nil)
        monitor.emitChange(in: child)
        await Task.yield()
        #expect(await fileSystem.recordedLoadRequests.count == loadCountAfterStopping)
    }

    @Test
    func successfulReloadRetriesAWatchThatInitiallyFailed() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let monitor = ControlledDirectoryMonitor(failedWatchAttempts: 1)
        let root = makeRoot()
        await fileSystem.setListing([], for: root)
        let model = FlashFileBrowserModel(
            fileSystem: fileSystem,
            directoryMonitor: monitor
        )

        model.setDirectoryMonitoringEnabled(true)
        await model.synchronize(sessionID: SessionID(), directory: root)

        #expect(monitor.watchAttemptCount == 2)
        #expect(monitor.watchedDirectory?.path == root.path)
    }

    @Test
    func sustainedDirectoryChurnKeepsOnePendingReloadAndConverges() async throws {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let monitor = ControlledDirectoryMonitor()
        let root = makeRoot()
        await fileSystem.setListing([], for: root)

        let model = FlashFileBrowserModel(
            fileSystem: fileSystem,
            directoryMonitor: monitor
        )
        model.setDirectoryMonitoringEnabled(true)
        defer {
            model.setDirectoryMonitoringEnabled(false)
            Task {
                await fileSystem.resumeAllPendingLoads(returning: [])
            }
        }
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setSuspendingLoads(true)

        monitor.emitChange(in: root)
        try #require(await fileSystem.waitForLoadCount(2))
        for _ in 0..<100 {
            monitor.emitChange(in: root)
        }
        await Task.yield()
        #expect(await fileSystem.recordedLoadRequests.count == 2)

        let firstRefresh = try #require(
            await fileSystem.recordedLoadRequests.last
        )
        let intermediate = makeItem("intermediate.swift", in: root)
        #expect(await fileSystem.resumeLoad(
            firstRefresh.id,
            returning: [intermediate]
        ))

        try #require(await fileSystem.waitForLoadCount(3))
        #expect(await fileSystem.recordedLoadRequests.count == 3)
        let secondRefresh = try #require(
            await fileSystem.recordedLoadRequests.last
        )
        for _ in 0..<100 {
            monitor.emitChange(in: root)
        }
        await Task.yield()
        #expect(await fileSystem.recordedLoadRequests.count == 3)
        let secondIntermediate = makeItem("second-intermediate.swift", in: root)
        #expect(await fileSystem.resumeLoad(
            secondRefresh.id,
            returning: [secondIntermediate]
        ))

        try #require(await fileSystem.waitForLoadCount(4))
        #expect(await fileSystem.recordedLoadRequests.count == 4)
        let finalRefresh = try #require(
            await fileSystem.recordedLoadRequests.last
        )
        let latest = makeItem("latest.swift", in: root)
        #expect(await fileSystem.resumeLoad(
            finalRefresh.id,
            returning: [latest]
        ))
        #expect(await waitUntil { model.items == [latest] })
        #expect(await fileSystem.recordedLoadRequests.count == 4)
    }

    @Test
    func directoryEventDuringBrowserMutationGetsAFollowUpReload() async throws {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let monitor = ControlledDirectoryMonitor()
        let root = makeRoot()
        let original = makeItem("original.swift", in: root)
        let createdExternally = makeItem("created-by-claude.swift", in: root)
        await fileSystem.setListing([original], for: root)

        let model = FlashFileBrowserModel(
            fileSystem: fileSystem,
            directoryMonitor: monitor
        )
        model.setDirectoryMonitoringEnabled(true)
        defer {
            model.setDirectoryMonitoringEnabled(false)
            Task {
                await fileSystem.resumeAllPendingLoads(returning: [])
            }
        }
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setSuspendingLoads(true)

        let operationTask = Task { @MainActor in
            await model.createFolder(named: "Browser Folder")
        }
        try #require(await fileSystem.waitForLoadCount(2))
        #expect(model.isPerformingOperation)

        // The browser's explicit reload is already in flight when an external
        // process changes the same directory.
        monitor.emitChange(in: root)
        let explicitReload = try #require(
            await fileSystem.recordedLoadRequests.last
        )
        #expect(await fileSystem.resumeLoad(
            explicitReload.id,
            returning: [original]
        ))
        await operationTask.value

        try #require(await fileSystem.waitForLoadCount(3))
        let followUpReload = try #require(
            await fileSystem.recordedLoadRequests.last
        )
        #expect(await fileSystem.resumeLoad(
            followUpReload.id,
            returning: [original, createdExternally]
        ))

        #expect(await waitUntil {
            model.items.contains(createdExternally)
        })
        #expect(await fileSystem.recordedLoadRequests.count == 3)
    }

    @Test
    func staleLoadCannotOverwriteTheNewSession() async throws {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        await fileSystem.setSuspendingLoads(true)
        let firstRoot = makeRoot()
        let secondRoot = makeRoot()
        let firstItem = makeItem("first.txt", in: firstRoot)
        let secondItem = makeItem("second.txt", in: secondRoot)
        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        defer {
            Task {
                await fileSystem.resumeAllPendingLoads(returning: [])
            }
        }

        let firstTask = Task { @MainActor in
            await model.synchronize(sessionID: SessionID(), directory: firstRoot)
        }
        try #require(await fileSystem.waitForLoadCount(1))

        let secondTask = Task { @MainActor in
            await model.synchronize(sessionID: SessionID(), directory: secondRoot)
        }
        try #require(await fileSystem.waitForLoadCount(2))

        let requests = await fileSystem.recordedLoadRequests
        let firstRequest = try #require(requests.first { $0.directory == firstRoot })
        let secondRequest = try #require(requests.first { $0.directory == secondRoot })
        let resumedSecond = await fileSystem.resumeLoad(
            secondRequest.id,
            returning: [secondItem]
        )
        #expect(resumedSecond)
        await secondTask.value

        let resumedFirst = await fileSystem.resumeLoad(
            firstRequest.id,
            returning: [firstItem]
        )
        #expect(resumedFirst)
        await firstTask.value

        #expect(model.sessionRoot == secondRoot)
        #expect(model.currentDirectory == secondRoot)
        #expect(model.items == [secondItem])
        #expect(!model.isLoading)
    }

    @Test
    func staleRootBindingCannotOverwriteTheNewestSession() async throws {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        await fileSystem.setSuspendingBindings(true)
        let firstRoot = makeRoot()
        let secondRoot = makeRoot()
        let secondItem = makeItem("second.txt", in: secondRoot)
        await fileSystem.setListing([secondItem], for: secondRoot)
        let model = FlashFileBrowserModel(fileSystem: fileSystem)

        let firstTask = Task { @MainActor in
            await model.synchronize(
                sessionID: SessionID(),
                directory: firstRoot
            )
        }
        await fileSystem.waitForBindingCount(1)

        let secondTask = Task { @MainActor in
            await model.synchronize(
                sessionID: SessionID(),
                directory: secondRoot
            )
        }
        try? await Task.sleep(for: .milliseconds(25))

        // The filesystem actor must never have two independently ordered root
        // changes in flight. The second binding begins only after the stale
        // first request has drained.
        #expect(await fileSystem.recordedBindingRequests.count == 1)
        let firstBinding = try #require(
            await fileSystem.recordedBindingRequests.first
        )
        #expect(await fileSystem.resumeBinding(firstBinding.id))
        await fileSystem.waitForBindingCount(2)

        let secondBinding = try #require(
            await fileSystem.recordedBindingRequests.last
        )
        #expect(secondBinding.root == secondRoot)
        #expect(await fileSystem.resumeBinding(secondBinding.id))
        await secondTask.value
        await firstTask.value

        #expect(model.sessionRoot == secondRoot)
        #expect(model.currentDirectory == secondRoot)
        #expect(model.items == [secondItem])
        #expect(
            await fileSystem.recordedBindingRequests.map(\.root) == [
                firstRoot,
                secondRoot,
            ]
        )
        #expect(await fileSystem.recordedLoadRequests.map(\.directory) == [secondRoot])
    }

    @Test
    func successfulMutationsUseCurrentBoundariesAndReload() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let original = makeItem("original.txt", in: root)
        let folder = makeItem("New Folder", in: root, isDirectory: true)
        let renamed = makeItem("renamed.txt", in: root)
        let copy = makeItem("renamed copy.txt", in: root)
        await fileSystem.setListing([original], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)

        await fileSystem.setListing([folder, original], for: root)
        await model.createFolder(named: folder.name)
        #expect(Set(model.items.map(\.id)) == Set([folder.id, original.id]))

        await fileSystem.setListing([folder, renamed], for: root)
        await model.rename(original, to: renamed.name)
        #expect(Set(model.items.map(\.id)) == Set([folder.id, renamed.id]))

        await fileSystem.setListing([folder, renamed, copy], for: root)
        await model.duplicate(renamed)
        #expect(
            Set(model.items.map(\.id)) == Set([folder.id, renamed.id, copy.id])
        )

        await fileSystem.setListing([folder, renamed], for: root)
        await model.moveToTrash(copy)
        #expect(Set(model.items.map(\.id)) == Set([folder.id, renamed.id]))
        #expect(!model.isPerformingOperation)
        #expect(model.errorMessage == nil)

        #expect(await fileSystem.recordedMutations == [
            .createFolder(name: folder.name, directory: root, allowedRoot: root),
            .rename(
                item: original.url,
                identity: original.identity,
                name: renamed.name,
                directory: root,
                allowedRoot: root
            ),
            .duplicate(
                item: renamed.url,
                identity: renamed.identity,
                directory: root,
                allowedRoot: root
            ),
            .moveToTrash(
                item: copy.url,
                identity: copy.identity,
                directory: root,
                allowedRoot: root
            ),
        ])
        #expect(await fileSystem.recordedLoadRequests.count == 5)
    }

    @Test
    func mutationErrorIsPresentedAndReloadsToReconcilePossibleCommit() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let item = makeItem("original.txt", in: root)
        await fileSystem.setListing([item], for: root)
        await fileSystem.setMutationError(
            .itemAlreadyExists("original copy.txt"),
            for: .duplicate
        )

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let loadCount = await fileSystem.recordedLoadRequests.count
        await model.duplicate(item)

        #expect(
            model.errorMessage == FlashFileBrowserFileSystemError
                .itemAlreadyExists("original copy.txt")
                .localizedDescription
        )
        #expect(model.items == [item])
        #expect(!model.isPerformingOperation)
        #expect(await fileSystem.recordedLoadRequests.count == loadCount + 1)
        #expect(await fileSystem.recordedMutations == [
            .duplicate(
                item: item.url,
                identity: item.identity,
                directory: root,
                allowedRoot: root
            ),
        ])

        model.clearError()
        #expect(model.errorMessage == nil)
    }

    @Test
    func createErrorReloadsBecauseTheFinalPathMayHaveCommitted() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let committedFolder = makeItem(
            "Committed Folder",
            in: root,
            isDirectory: true
        )
        await fileSystem.setListing([], for: root)
        await fileSystem.setMutationError(
            .itemIsNotCurrent,
            for: .createFolder
        )

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        let loadCount = await fileSystem.recordedLoadRequests.count
        await fileSystem.setListing([committedFolder], for: root)

        await model.createFolder(named: committedFolder.name)

        #expect(model.items == [committedFolder])
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.itemIsNotCurrent.localizedDescription
        )
        #expect(await fileSystem.recordedLoadRequests.count == loadCount + 1)
        #expect(await fileSystem.recordedMutations == [
            .createFolder(
                name: committedFolder.name,
                directory: root,
                allowedRoot: root
            ),
        ])
    }

    @Test
    func staleDialogItemCannotMutateReplacementAtTheSamePath() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let original = makeItem(
            "report.txt",
            in: root,
            identity: .init(device: 1, inode: 100)
        )
        let replacement = makeItem(
            "report.txt",
            in: root,
            identity: .init(device: 1, inode: 200)
        )
        await fileSystem.setListing([original], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setListing([replacement], for: root)
        await model.reload()

        await model.moveToTrash(original)

        #expect(model.items == [replacement])
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.itemIsNotCurrent.localizedDescription
        )
        #expect(await fileSystem.recordedMutations.isEmpty)
    }

    @Test
    func pasteDeduplicatesSourcesReloadsOnceAndUsesCapturedDirectory() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let outside = makeRoot()
        let firstSource = outside.appendingPathComponent("first.txt")
        let secondSource = outside.appendingPathComponent("second.txt")
        let firstCopy = makeItem("first.txt", in: root)
        let secondCopy = makeItem("second.txt", in: root)
        await fileSystem.setListing([], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setListing([firstCopy, secondCopy], for: root)
        await model.paste([firstSource, firstSource, secondSource])

        #expect(Set(model.items.map(\.id)) == Set([firstCopy.id, secondCopy.id]))
        #expect(await fileSystem.recordedMutations == [
            .copyItem(source: firstSource, directory: root, allowedRoot: root),
            .copyItem(source: secondSource, directory: root, allowedRoot: root),
        ])
        #expect(await fileSystem.recordedLoadRequests.count == 2)
        #expect(model.errorMessage == nil)
    }

    @Test
    func pasteRejectsClipboardWithoutFileURLsWithoutStartingAnOperation() async throws {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        await fileSystem.setListing([], for: root)
        let remote = try #require(URL(string: "https://example.com/file.txt"))

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await model.paste([remote])

        #expect(
            model.errorMessage ==
                FlashFileBrowserModelError.nothingToPaste.localizedDescription
        )
        #expect(!model.isPerformingOperation)
        #expect(await fileSystem.recordedMutations.isEmpty)
        #expect(await fileSystem.recordedLoadRequests.count == 1)
    }

    @Test
    func partialPasteReloadsBeforePresentingProgressError() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let outside = makeRoot()
        let firstSource = outside.appendingPathComponent("first.txt")
        let secondSource = outside.appendingPathComponent("missing.txt")
        let thirdSource = outside.appendingPathComponent("must-not-copy.txt")
        let firstCopy = makeItem("first.txt", in: root)
        await fileSystem.setListing([], for: root)
        await fileSystem.setCopyError(
            .copySourceUnavailable(secondSource.lastPathComponent),
            for: secondSource
        )

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setListing([firstCopy], for: root)
        await model.paste([firstSource, secondSource, thirdSource])

        #expect(model.items == [firstCopy])
        #expect(await fileSystem.recordedLoadRequests.count == 2)
        #expect(
            model.errorMessage == FlashFileBrowserFileSystemError
                .batchOperationFailed(
                    completed: 1,
                    total: 3,
                    reason: FlashFileBrowserFileSystemError
                        .copySourceUnavailable(secondSource.lastPathComponent)
                        .localizedDescription
                )
                .localizedDescription
        )
        #expect(await fileSystem.recordedMutations == [
            .copyItem(source: firstSource, directory: root, allowedRoot: root),
            .copyItem(source: secondSource, directory: root, allowedRoot: root),
        ])
        #expect(!model.isPerformingOperation)
    }

    @Test
    func cancelledPartialPasteReloadsWithoutPresentingAnError() async throws {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let outside = makeRoot()
        let firstSource = outside.appendingPathComponent("first.txt")
        let secondSource = outside.appendingPathComponent("cancel.txt")
        let thirdSource = outside.appendingPathComponent("must-not-copy.txt")
        let firstCopy = makeItem("first.txt", in: root)
        await fileSystem.setListing([], for: root)
        await fileSystem.setCopySuspended(true, for: secondSource)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setListing([firstCopy], for: root)
        let operationTask = Task { @MainActor in
            await model.paste([firstSource, secondSource, thirdSource])
        }
        defer { operationTask.cancel() }
        try #require(await fileSystem.waitForMutationCount(2))
        operationTask.cancel()
        await operationTask.value

        #expect(model.items == [firstCopy])
        #expect(model.errorMessage == nil)
        #expect(await fileSystem.recordedLoadRequests.count == 2)
        #expect(await fileSystem.recordedMutations == [
            .copyItem(source: firstSource, directory: root, allowedRoot: root),
            .copyItem(source: secondSource, directory: root, allowedRoot: root),
        ])
        #expect(!model.isPerformingOperation)
    }

    @Test
    func batchTrashRejectsAnyStaleCandidateBeforeStarting() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let first = makeItem("first.txt", in: root)
        let stale = makeItem(
            "second.txt",
            in: root,
            identity: .init(device: 1, inode: 20)
        )
        let replacement = makeItem(
            "second.txt",
            in: root,
            identity: .init(device: 1, inode: 21)
        )
        await fileSystem.setListing([first, stale], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setListing([first, replacement], for: root)
        await model.reload()
        await model.moveToTrash([first, stale])

        #expect(await fileSystem.recordedMutations.isEmpty)
        #expect(model.items == [first, replacement])
        #expect(
            model.errorMessage ==
                FlashFileBrowserFileSystemError.itemIsNotCurrent.localizedDescription
        )
    }

    @Test
    func batchTrashMovesEveryCurrentItemAndReloadsOnce() async {
        let fileSystem = ControlledFlashFileBrowserFileSystem()
        let root = makeRoot()
        let first = makeItem("first.txt", in: root)
        let second = makeItem("second.txt", in: root)
        await fileSystem.setListing([first, second], for: root)

        let model = FlashFileBrowserModel(fileSystem: fileSystem)
        await model.synchronize(sessionID: SessionID(), directory: root)
        await fileSystem.setListing([], for: root)
        await model.moveToTrash([second, first])

        #expect(model.items.isEmpty)
        #expect(await fileSystem.recordedMutations == [
            .moveToTrash(
                item: second.url,
                identity: second.identity,
                directory: root,
                allowedRoot: root
            ),
            .moveToTrash(
                item: first.url,
                identity: first.identity,
                directory: root,
                allowedRoot: root
            ),
        ])
        #expect(await fileSystem.recordedLoadRequests.count == 2)
    }

    @Test
    func navigationRejectsFolderDeletedAfterListing() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("FlashFileBrowserDeletedFolder-\(UUID().uuidString)")
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let model = FlashFileBrowserModel(
            fileSystem: LocalFlashFileBrowserFileSystem()
        )
        await model.synchronize(sessionID: SessionID(), directory: root)
        let childItem = try #require(model.items.first { $0.name == "Child" })
        try fileManager.removeItem(at: child)

        await model.navigate(to: childItem)

        #expect(model.currentDirectory?.path == root.standardizedFileURL.path)
        #expect(!model.canGoBack)
        #expect(model.errorMessage != nil)
    }
}

private extension FlashFileBrowserModelTests {
    func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashFileBrowserModelTests-\(UUID().uuidString)")
            .standardizedFileURL
    }

    func makeItem(
        _ name: String,
        in directory: URL,
        identity: FlashFileBrowserItemIdentity? = nil,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isSymbolicLink: Bool = false,
        isHidden: Bool = false
    ) -> FlashFileBrowserItem {
        FlashFileBrowserItem(
            url: directory.appendingPathComponent(name).standardizedFileURL,
            identity: identity ?? .init(
                device: 1,
                inode: name.utf8.reduce(5381) { partialResult, byte in
                    partialResult &* 33 &+ UInt64(byte)
                }
            ),
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isHidden: isHidden,
            modificationDate: nil
        )
    }
}

@MainActor
private final class ControlledDirectoryMonitor:
    FlashFileBrowserDirectoryMonitoring {
    private(set) var watchedDirectory: URL?
    private(set) var watchAttemptCount = 0
    private var failedWatchAttempts: Int
    private var handlersByPath: [String: ChangeHandler] = [:]

    init(failedWatchAttempts: Int = 0) {
        self.failedWatchAttempts = failedWatchAttempts
    }

    @discardableResult
    func watch(
        _ directory: URL,
        onChange: @escaping ChangeHandler
    ) -> Bool {
        watchAttemptCount += 1
        if failedWatchAttempts > 0 {
            failedWatchAttempts -= 1
            watchedDirectory = nil
            return false
        }
        let normalized = FlashFileBrowserPathPolicy.standardized(directory)
        watchedDirectory = normalized
        handlersByPath[normalized.path] = onChange
        return true
    }

    func stop() {
        watchedDirectory = nil
    }

    func emitChange(in directory: URL) {
        let normalized = FlashFileBrowserPathPolicy.standardized(directory)
        handlersByPath[normalized.path]?(normalized)
    }
}

private actor ControlledFlashFileBrowserFileSystem: FlashFileBrowserFileSystem {
    struct BindingRequest: Equatable, Sendable {
        let id: Int
        let root: URL
    }

    struct LoadRequest: Equatable, Sendable {
        let id: Int
        let directory: URL
        let showingHiddenFiles: Bool
    }

    enum MutationKind: Hashable, Sendable {
        case createFolder
        case rename
        case duplicate
        case copyItem
        case moveToTrash
    }

    enum Mutation: Equatable, Sendable {
        case createFolder(name: String, directory: URL, allowedRoot: URL)
        case rename(
            item: URL,
            identity: FlashFileBrowserItemIdentity,
            name: String,
            directory: URL,
            allowedRoot: URL
        )
        case duplicate(
            item: URL,
            identity: FlashFileBrowserItemIdentity,
            directory: URL,
            allowedRoot: URL
        )
        case copyItem(source: URL, directory: URL, allowedRoot: URL)
        case moveToTrash(
            item: URL,
            identity: FlashFileBrowserItemIdentity,
            directory: URL,
            allowedRoot: URL
        )
    }

    private struct ListingKey: Hashable {
        let directory: URL
        let showingHiddenFiles: Bool
    }

    private struct BindingWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var listings: [ListingKey: [FlashFileBrowserItem]] = [:]
    private var mutationErrors: [MutationKind: FlashFileBrowserFileSystemError] = [:]
    private var copyErrorsBySource: [URL: FlashFileBrowserFileSystemError] = [:]
    private var suspendedCopySources: Set<URL> = []
    private var pendingLoads: [
        Int: CheckedContinuation<[FlashFileBrowserItem], any Error>
    ] = [:]
    private var pendingBindings: [
        Int: CheckedContinuation<Void, any Error>
    ] = [:]
    private var bindingWaiters: [BindingWaiter] = []
    private var suspendsLoads = false
    private var suspendsBindings = false
    private var nextLoadID = 0
    private var nextBindingID = 0

    private(set) var recordedBindingRequests: [BindingRequest] = []
    private(set) var recordedLoadRequests: [LoadRequest] = []
    private(set) var recordedMutations: [Mutation] = []

    func bindRoot(_ root: URL) async throws {
        let request = BindingRequest(
            id: nextBindingID,
            root: FlashFileBrowserPathPolicy.standardized(root)
        )
        nextBindingID += 1
        recordedBindingRequests.append(request)
        resumeSatisfiedBindingWaiters()

        if suspendsBindings {
            try await withCheckedThrowingContinuation { continuation in
                pendingBindings[request.id] = continuation
            }
        }
    }

    func isNavigationAllowed(
        _ directory: URL,
        allowedRoot: URL
    ) -> Bool {
        FlashFileBrowserPathPolicy.contains(directory, in: allowedRoot) &&
            FlashFileBrowserPathPolicy.containsResolved(directory, in: allowedRoot)
    }

    func setListing(
        _ items: [FlashFileBrowserItem],
        for directory: URL,
        showingHiddenFiles: Bool = false
    ) {
        listings[ListingKey(
            directory: FlashFileBrowserPathPolicy.standardized(directory),
            showingHiddenFiles: showingHiddenFiles
        )] = items
    }

    func setMutationError(
        _ error: FlashFileBrowserFileSystemError?,
        for kind: MutationKind
    ) {
        mutationErrors[kind] = error
    }

    func setCopyError(
        _ error: FlashFileBrowserFileSystemError?,
        for source: URL
    ) {
        copyErrorsBySource[source.standardizedFileURL] = error
    }

    func setCopySuspended(_ suspended: Bool, for source: URL) {
        let source = source.standardizedFileURL
        if suspended {
            suspendedCopySources.insert(source)
        } else {
            suspendedCopySources.remove(source)
        }
    }

    func setSuspendingLoads(_ suspendsLoads: Bool) {
        self.suspendsLoads = suspendsLoads
    }

    func setSuspendingBindings(_ suspendsBindings: Bool) {
        self.suspendsBindings = suspendsBindings
    }

    func waitForLoadCount(
        _ count: Int,
        timeoutNanoseconds: UInt64 = 15_000_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while recordedLoadRequests.count < count,
              DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
        return recordedLoadRequests.count >= count
    }

    func waitForMutationCount(
        _ count: Int,
        timeoutNanoseconds: UInt64 = 15_000_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while recordedMutations.count < count,
              DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
        return recordedMutations.count >= count
    }

    func waitForBindingCount(_ count: Int) async {
        guard recordedBindingRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            bindingWaiters.append(BindingWaiter(
                count: count,
                continuation: continuation
            ))
        }
    }

    @discardableResult
    func resumeBinding(_ id: Int) -> Bool {
        guard let continuation = pendingBindings.removeValue(forKey: id) else {
            return false
        }
        continuation.resume()
        return true
    }

    @discardableResult
    func resumeLoad(
        _ id: Int,
        returning items: [FlashFileBrowserItem]
    ) -> Bool {
        guard let continuation = pendingLoads.removeValue(forKey: id) else {
            return false
        }
        continuation.resume(returning: items)
        return true
    }

    func resumeAllPendingLoads(returning items: [FlashFileBrowserItem]) {
        suspendsLoads = false
        let continuations = Array(pendingLoads.values)
        pendingLoads.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(returning: items)
        }
    }

    func contents(
        of directory: URL,
        showingHiddenFiles: Bool,
        allowedRoot: URL
    ) async throws -> [FlashFileBrowserItem] {
        try Task.checkCancellation()
        guard FlashFileBrowserPathPolicy.contains(directory, in: allowedRoot),
              FlashFileBrowserPathPolicy.containsResolved(directory, in: allowedRoot) else {
            throw FlashFileBrowserFileSystemError.outsideWorkingDirectory
        }

        let request = LoadRequest(
            id: nextLoadID,
            directory: FlashFileBrowserPathPolicy.standardized(directory),
            showingHiddenFiles: showingHiddenFiles
        )
        nextLoadID += 1
        recordedLoadRequests.append(request)

        if suspendsLoads {
            let items = try await withCheckedThrowingContinuation { continuation in
                pendingLoads[request.id] = continuation
            }
            try Task.checkCancellation()
            return items
        }

        return listings[ListingKey(
            directory: request.directory,
            showingHiddenFiles: showingHiddenFiles
        )] ?? []
    }

    func isHidden(
        _ item: URL,
        allowedRoot: URL
    ) -> Bool {
        let path = item.standardizedFileURL.path
        return listings.values
            .joined()
            .contains {
                $0.url.standardizedFileURL.path == path && $0.isHidden
            }
    }

    func createFolder(
        named name: String,
        in directory: URL,
        allowedRoot: URL
    ) throws -> URL {
        recordedMutations.append(.createFolder(
            name: name,
            directory: directory,
            allowedRoot: allowedRoot
        ))
        try throwMutationError(for: .createFolder)
        return directory.appendingPathComponent(name).standardizedFileURL
    }

    func rename(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        to name: String,
        in directory: URL,
        allowedRoot: URL
    ) throws -> URL {
        recordedMutations.append(.rename(
            item: item,
            identity: expectedIdentity,
            name: name,
            directory: directory,
            allowedRoot: allowedRoot
        ))
        try throwMutationError(for: .rename)
        return directory.appendingPathComponent(name).standardizedFileURL
    }

    func duplicate(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in directory: URL,
        allowedRoot: URL
    ) throws -> URL {
        recordedMutations.append(.duplicate(
            item: item,
            identity: expectedIdentity,
            directory: directory,
            allowedRoot: allowedRoot
        ))
        try throwMutationError(for: .duplicate)
        return directory
            .appendingPathComponent(item.deletingPathExtension().lastPathComponent + " copy")
            .appendingPathExtension(item.pathExtension)
            .standardizedFileURL
    }

    func copyItem(
        _ source: URL,
        to directory: URL,
        allowedRoot: URL
    ) async throws -> URL {
        let source = source.standardizedFileURL
        recordedMutations.append(.copyItem(
            source: source,
            directory: directory,
            allowedRoot: allowedRoot
        ))
        while suspendedCopySources.contains(source) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        if let error = copyErrorsBySource[source] { throw error }
        try throwMutationError(for: .copyItem)
        return directory
            .appendingPathComponent(source.lastPathComponent)
            .standardizedFileURL
    }

    func moveToTrash(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in directory: URL,
        allowedRoot: URL
    ) throws {
        recordedMutations.append(.moveToTrash(
            item: item,
            identity: expectedIdentity,
            directory: directory,
            allowedRoot: allowedRoot
        ))
        try throwMutationError(for: .moveToTrash)
    }

    private func throwMutationError(for kind: MutationKind) throws {
        if let error = mutationErrors[kind] {
            throw error
        }
    }

    private func resumeSatisfiedBindingWaiters() {
        let satisfied = bindingWaiters.filter {
            recordedBindingRequests.count >= $0.count
        }
        bindingWaiters.removeAll {
            recordedBindingRequests.count >= $0.count
        }
        satisfied.forEach { $0.continuation.resume() }
    }
}
