import Combine
import Foundation

/// Application-owned state for the file browser attached to one terminal view.
///
/// Filesystem work is delegated to an asynchronous service so directory reads
/// and mutations never block terminal rendering. Every load carries a
/// generation number; a result from an old session or directory is discarded
/// when it eventually completes.
@MainActor
final class FlashFileBrowserModel: ObservableObject {
    /// The potentially large payload stays outside `ObservableObject` change
    /// comparison. Views observe the scalar revision and pull the immutable
    /// snapshot only when it changes.
    private(set) var items: [FlashFileBrowserItem] = [] {
        didSet { itemsRevision &+= 1 }
    }
    @Published private(set) var itemsRevision: UInt = 0
    @Published private(set) var currentDirectory: URL? {
        didSet {
            guard oldValue?.standardizedFileURL.path !=
                    currentDirectory?.standardizedFileURL.path else { return }
            rebindDirectoryMonitor()
        }
    }
    @Published private(set) var sessionRoot: URL?
    @Published private(set) var isLoading = false
    @Published var isPerformingOperation = false
    @Published private(set) var showingHiddenFiles: Bool
    @Published var errorMessage: String?

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    let fileSystem: any FlashFileBrowserFileSystem
    private let directoryMonitor: any FlashFileBrowserDirectoryMonitoring
    private let snapshotWorker = FlashFileBrowserSnapshotWorker()
    private(set) var synchronizedSessionID: SessionWorkspace.SessionID?
    private var backHistory: [URL] = []
    var forwardHistory: [URL] = []
    private var loadGeneration: UInt = 0
    var operationGeneration: UInt = 0
    private var synchronizationGeneration: UInt = 0
    private var directoryMonitorGeneration: UInt = 0
    private var revealGeneration: UInt = 0
    private var transientRevealedHiddenTarget: URL?
    private var directoryMonitoringEnabled = false
    var externalReloadPending = false
    private var externalReloadTask: Task<Void, Never>?
    private var rootBindingTail: Task<Void, Never>?
    private var pendingRootBindingCount = 0

    init(
        fileSystem: any FlashFileBrowserFileSystem = LocalFlashFileBrowserFileSystem(),
        directoryMonitor: (any FlashFileBrowserDirectoryMonitoring)? = nil,
        showingHiddenFiles: Bool = false
    ) {
        self.fileSystem = fileSystem
        self.directoryMonitor = directoryMonitor ?? FlashFileBrowserDirectoryMonitor()
        self.showingHiddenFiles = showingHiddenFiles
    }

    /// Synchronize the browser with the selected terminal session.
    ///
    /// A temporary nil directory from the same session preserves the last
    /// usable location. A different session with no directory clears all
    /// state, preventing one session's files from appearing under another.
    func synchronize(
        sessionID: SessionWorkspace.SessionID,
        directory: URL?
    ) async {
        synchronizationGeneration &+= 1
        let generation = synchronizationGeneration
        invalidateReveal()
        let normalizedDirectory = normalizedFileURL(directory)
        let isDifferentSession = synchronizedSessionID != sessionID

        if isDifferentSession {
            synchronizedSessionID = sessionID
            resetNavigation(to: nil)
            invalidateOperations()
        }

        // Shell integration can briefly publish nil while rebinding a
        // surface. Keep the last valid directory for this same session.
        guard let normalizedDirectory else {
            // If an older CWD change is already binding, queue the preserved
            // root behind it so that stale actor state cannot outlive this nil
            // update. A different session with no root has nothing to repair.
            guard !isDifferentSession,
                  pendingRootBindingCount > 0,
                  let preservedRoot = sessionRoot else { return }
            let bindingError = await enqueueRootBinding(preservedRoot)
            guard generation == synchronizationGeneration,
                  sessionID == synchronizedSessionID else { return }
            if let bindingError {
                errorMessage = bindingError
            }
            return
        }

        let changesRoot = normalizedDirectory != sessionRoot
        guard changesRoot || pendingRootBindingCount > 0 else {
            await reload()
            return
        }

        if changesRoot {
            clearTransientRevealedHiddenTarget()
        }
        let bindingError = await enqueueRootBinding(normalizedDirectory)
        guard generation == synchronizationGeneration,
              sessionID == synchronizedSessionID else { return }
        if let bindingError {
            if changesRoot {
                resetNavigation(to: nil)
            }
            errorMessage = bindingError
            return
        }

        if changesRoot {
            resetNavigation(to: normalizedDirectory)
            invalidateOperations()
        }
        await reload()
    }

    /// Reload the visible directory. Older concurrent loads cannot overwrite
    /// a newer session, navigation, or hidden-file choice.
    func reload() async {
        await load(showsLoadingIndicator: true)
    }

    /// Keeps the vnode monitor alive only while this browser is visible for
    /// the selected session. The current directory observer handles rebinding
    /// when the user navigates inside the session root.
    func setDirectoryMonitoringEnabled(_ enabled: Bool) {
        guard directoryMonitoringEnabled != enabled else { return }
        directoryMonitoringEnabled = enabled
        rebindDirectoryMonitor()
    }

    private func load(showsLoadingIndicator: Bool) async {
        guard let directory = currentDirectory,
              let root = sessionRoot else {
            invalidateLoads(clearItems: true)
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedDirectory = directory
        let requestedShowingHiddenFiles = showingHiddenFiles
        let requestedTransientTarget = transientRevealedHiddenTarget
        let requestsHiddenFiles = requestedShowingHiddenFiles ||
            requestedTransientTarget != nil

        if showsLoadingIndicator, !isLoading {
            isLoading = true
        }
        if errorMessage != nil {
            errorMessage = nil
        }

        do {
            let loadedItems = try await fileSystem.contents(
                of: requestedDirectory,
                showingHiddenFiles: requestsHiddenFiles,
                allowedRoot: root
            )

            guard generation == loadGeneration,
                  requestedDirectory == currentDirectory,
                  root == sessionRoot,
                  requestedShowingHiddenFiles == showingHiddenFiles,
                  requestedTransientTarget == transientRevealedHiddenTarget else { return }

            let reconciliation = await snapshotWorker.reconcile(
                loadedItems: loadedItems,
                currentItems: items,
                showingHiddenFiles: requestedShowingHiddenFiles,
                transientTarget: requestedTransientTarget
            )

            // Revalidate after the actor hop. A navigation, preference, reveal,
            // or newer load that happened during comparison owns the UI now.
            guard generation == loadGeneration,
                  requestedDirectory == currentDirectory,
                  root == sessionRoot,
                  requestedShowingHiddenFiles == showingHiddenFiles,
                  requestedTransientTarget == transientRevealedHiddenTarget else { return }

            if reconciliation.shouldPublish {
                items = reconciliation.presentedItems
            }
            if requestedTransientTarget != nil,
               !reconciliation.containsTransientTarget {
                transientRevealedHiddenTarget = nil
            }
            ensureDirectoryMonitorBound(to: requestedDirectory)
            if isLoading {
                isLoading = false
            }
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            if isLoading {
                isLoading = false
            }
        } catch {
            guard generation == loadGeneration,
                  requestedDirectory == currentDirectory,
                  root == sessionRoot,
                  requestedShowingHiddenFiles == showingHiddenFiles,
                  requestedTransientTarget == transientRevealedHiddenTarget else { return }

            if isLoading {
                isLoading = false
            }
            if !items.isEmpty {
                items = []
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Navigate from a current row. Packages remain launchable files rather
    /// than browsable folders, matching Finder behavior.
    func navigate(to item: FlashFileBrowserItem) async {
        guard let currentItem = currentItem(matching: item) else {
            present(FlashFileBrowserFileSystemError.itemIsNotCurrent)
            return
        }
        guard currentItem.isNavigableFolder else {
            present(FlashFileBrowserModelError.itemIsNotFolder)
            return
        }

        await navigate(to: currentItem.url)
    }

    /// Navigate to a directory within the current session root. This overload
    /// supports breadcrumbs while retaining the same root-boundary policy.
    func navigate(to directory: URL) async {
        dismissReveal()
        guard let destination = normalizedFileURL(directory),
              let root = sessionRoot else {
            present(FlashFileBrowserModelError.workingDirectoryUnavailable)
            return
        }
        guard destination != currentDirectory else { return }
        guard await validateNavigationDestination(destination, root: root) else { return }

        if let currentDirectory {
            backHistory.append(currentDirectory)
        }
        forwardHistory.removeAll(keepingCapacity: true)
        currentDirectory = destination
        clearItemsIfNeeded()
        errorMessage = nil
        await reload()
    }

    /// Reveals a terminal-linked entry using Finder-style navigation: show its
    /// parent directory, refresh the listing, and return the current row that
    /// represents the lexical path. The target itself is never resolved so a
    /// symlink inside the working directory remains selectable as that symlink.
    func reveal(
        _ lexicalURL: URL,
        refreshCurrentDirectory: Bool = true
    ) async -> FlashFileBrowserItem? {
        revealGeneration &+= 1
        let generation = revealGeneration
        guard let target = normalizedFileURL(lexicalURL),
              let root = sessionRoot,
              let sessionID = synchronizedSessionID else {
            present(FlashFileBrowserModelError.workingDirectoryUnavailable)
            return nil
        }
        guard FlashFileBrowserPathPolicy.contains(target, in: root) else {
            present(FlashFileBrowserFileSystemError.outsideWorkingDirectory)
            return nil
        }

        if transientRevealedHiddenTarget != target {
            clearTransientRevealedHiddenTarget()
        }

        // The root has no selectable parent row inside this browser. Treat it
        // as a request to return to the root instead.
        let revealsRoot = target == root
        let destination = revealsRoot
            ? root
            : FlashFileBrowserPathPolicy.standardized(
                target.deletingLastPathComponent()
            )

        guard await validateNavigationDestination(destination, root: root) else {
            return nil
        }
        guard isCurrentReveal(generation) else { return nil }

        let changesDirectory = destination != currentDirectory
        if changesDirectory {
            if let currentDirectory {
                backHistory.append(currentDirectory)
            }
            forwardHistory.removeAll(keepingCapacity: true)
            currentDirectory = destination
            clearItemsIfNeeded()
            errorMessage = nil
        }
        if changesDirectory || refreshCurrentDirectory {
            await reload()
        }

        guard isCurrentReveal(generation),
              sessionID == synchronizedSessionID,
              root == sessionRoot,
              destination == currentDirectory else { return nil }
        guard errorMessage == nil else {
            clearTransientRevealedHiddenTarget()
            return nil
        }
        guard !revealsRoot else { return nil }

        if let item = listedItem(at: target) {
            return item
        }

        // Explicitly revealing a hidden file loads hidden entries only long
        // enough to retain this one target. The user's persistent preference
        // remains untouched and every other hidden row stays excluded.
        let targetIsHidden: Bool
        if target.lastPathComponent.hasPrefix(".") {
            targetIsHidden = true
        } else {
            targetIsHidden = await fileSystem.isHidden(target, allowedRoot: root)
        }
        guard isCurrentReveal(generation),
              sessionID == synchronizedSessionID,
              root == sessionRoot,
              destination == currentDirectory else { return nil }

        if !showingHiddenFiles, targetIsHidden {
            transientRevealedHiddenTarget = target
            await reload()
            guard isCurrentReveal(generation),
                  sessionID == synchronizedSessionID,
                  root == sessionRoot,
                  destination == currentDirectory else { return nil }
            guard errorMessage == nil else {
                clearTransientRevealedHiddenTarget()
                return nil
            }
            if let item = listedItem(at: target) {
                return item
            }
        }

        guard isCurrentReveal(generation) else { return nil }
        present(FlashFileBrowserModelError.itemUnavailable)
        return nil
    }

    func goBack() async {
        dismissReveal()
        guard let destination = backHistory.last,
              let currentDirectory,
              let root = sessionRoot else { return }
        guard await validateNavigationDestination(destination, root: root) else { return }

        backHistory.removeLast()
        forwardHistory.append(currentDirectory)
        self.currentDirectory = destination
        clearItemsIfNeeded()
        errorMessage = nil
        await reload()
    }

    func goForward() async {
        dismissReveal()
        guard let destination = forwardHistory.last,
              let currentDirectory,
              let root = sessionRoot else { return }
        guard await validateNavigationDestination(destination, root: root) else { return }

        forwardHistory.removeLast()
        backHistory.append(currentDirectory)
        self.currentDirectory = destination
        clearItemsIfNeeded()
        errorMessage = nil
        await reload()
    }

    func goToRoot() async {
        dismissReveal()
        guard let root = sessionRoot else {
            present(FlashFileBrowserModelError.workingDirectoryUnavailable)
            return
        }
        guard root != currentDirectory else { return }
        guard await validateNavigationDestination(root, root: root) else { return }

        if let currentDirectory {
            backHistory.append(currentDirectory)
        }
        forwardHistory.removeAll(keepingCapacity: true)
        currentDirectory = root
        clearItemsIfNeeded()
        errorMessage = nil
        await reload()
    }

    func setShowingHiddenFiles(_ showingHiddenFiles: Bool) async {
        guard self.showingHiddenFiles != showingHiddenFiles else { return }

        invalidateReveal()
        self.showingHiddenFiles = showingHiddenFiles
        clearTransientRevealedHiddenTarget()
        if !showingHiddenFiles {
            removeHiddenItemsIfNeeded()
        }
        await reload()
    }

    /// Dismisses a one-row hidden-file reveal without changing the persisted
    /// hidden-file preference or performing another directory enumeration.
    func dismissReveal() {
        invalidateReveal()
        clearTransientRevealedHiddenTarget()
    }

    func clearError() {
        errorMessage = nil
    }

    private func rebindDirectoryMonitor() {
        directoryMonitorGeneration &+= 1
        externalReloadTask?.cancel()
        externalReloadTask = nil
        externalReloadPending = false
        directoryMonitor.stop()

        guard directoryMonitoringEnabled,
              let directory = currentDirectory else { return }

        ensureDirectoryMonitorBound(to: directory)
    }

    private func ensureDirectoryMonitorBound(to directory: URL) {
        guard directoryMonitoringEnabled,
              directory == currentDirectory else { return }
        directoryMonitor.watch(directory) { [weak self] changedDirectory in
            self?.directoryContentsDidChange(in: changedDirectory)
        }
    }

    private func directoryContentsDidChange(in changedDirectory: URL) {
        guard directoryMonitoringEnabled,
              changedDirectory.standardizedFileURL.path ==
                currentDirectory?.standardizedFileURL.path else { return }

        externalReloadPending = true
        startExternalReloadIfNeeded()
    }

    func startExternalReloadIfNeeded() {
        guard externalReloadPending,
              !isPerformingOperation,
              directoryMonitoringEnabled,
              externalReloadTask == nil else { return }

        let generation = directoryMonitorGeneration
        externalReloadTask = Task { @MainActor [weak self] in
            await self?.drainExternalReloads(generation: generation)
        }
    }

    /// Serializes refreshes generated by the directory monitor. Events that
    /// arrive while an enumeration is in flight request at most one follow-up
    /// pass, preventing a busy CLI command from building an I/O backlog.
    private func drainExternalReloads(generation: UInt) async {
        defer {
            if generation == directoryMonitorGeneration {
                externalReloadTask = nil
                startExternalReloadIfNeeded()
            }
        }

        while externalReloadPending {
            guard !Task.isCancelled,
                  generation == directoryMonitorGeneration,
                  directoryMonitoringEnabled,
                  !isPerformingOperation else { return }

            externalReloadPending = false
            let loadStart = ProcessInfo.processInfo.systemUptime
            await load(showsLoadingIndicator: items.isEmpty)

            // Only wait when another event arrived during the scan. Ordinary
            // single changes retain the monitor's normal 500-ms responsiveness.
            guard externalReloadPending else { continue }
            let duration = ProcessInfo.processInfo.systemUptime - loadStart
            let delay = FlashFileBrowserExternalReloadPolicy
                .delayNanoseconds(afterLoadDuration: duration)
            guard delay > 0 else { continue }

            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
        }
    }

    private func resetNavigation(to root: URL?) {
        clearTransientRevealedHiddenTarget()
        sessionRoot = root
        currentDirectory = root
        backHistory.removeAll(keepingCapacity: true)
        forwardHistory.removeAll(keepingCapacity: true)
        errorMessage = nil
        invalidateLoads(clearItems: true)
    }

    private func invalidateLoads(clearItems: Bool) {
        loadGeneration &+= 1
        isLoading = false
        if clearItems { clearItemsIfNeeded() }
    }

    /// Directory changes independently invalidate the presentation store, so
    /// an already-empty source must not manufacture a payload revision and a
    /// redundant projection request.
    private func clearItemsIfNeeded() {
        guard !items.isEmpty else { return }
        items = []
    }

    private func removeHiddenItemsIfNeeded() {
        let visibleItems = items.filter { !$0.isHidden }
        guard visibleItems.count != items.count else { return }
        items = visibleItems
    }

    private func invalidateOperations() {
        operationGeneration &+= 1
        isPerformingOperation = false
    }

    private func invalidateReveal() {
        revealGeneration &+= 1
    }

    private func clearTransientRevealedHiddenTarget() {
        guard transientRevealedHiddenTarget != nil else { return }
        transientRevealedHiddenTarget = nil
        invalidateLoads(clearItems: false)
        if !showingHiddenFiles {
            removeHiddenItemsIfNeeded()
        }
    }

    private func isCurrentReveal(_ generation: UInt) -> Bool {
        generation == revealGeneration && !Task.isCancelled
    }

    func currentItem(
        matching candidate: FlashFileBrowserItem
    ) -> FlashFileBrowserItem? {
        guard let currentDirectory,
              FlashFileBrowserPathPolicy.isDirectChild(candidate.url, of: currentDirectory)
        else { return nil }

        return items.first(where: {
            $0.id == candidate.id && $0.identity == candidate.identity
        })
    }

    private func listedItem(at url: URL) -> FlashFileBrowserItem? {
        let path = FlashFileBrowserPathPolicy.standardized(url).path
        return items.first {
            itemURL($0).path == path
        }
    }

    private func itemURL(_ item: FlashFileBrowserItem) -> URL {
        FlashFileBrowserPathPolicy.standardized(item.url)
    }

    func present(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    private func validateNavigationDestination(
        _ destination: URL,
        root: URL
    ) async -> Bool {
        guard FlashFileBrowserPathPolicy.contains(destination, in: root) else {
            present(FlashFileBrowserFileSystemError.outsideWorkingDirectory)
            return false
        }

        let requestedSessionID = synchronizedSessionID
        let requestedCurrentDirectory = currentDirectory
        let isAllowed = await fileSystem.isNavigationAllowed(
            destination,
            allowedRoot: root
        )
        guard requestedSessionID == synchronizedSessionID,
              requestedCurrentDirectory == currentDirectory,
              root == sessionRoot else { return false }
        guard isAllowed else {
            present(FlashFileBrowserFileSystemError.outsideWorkingDirectory)
            return false
        }

        return true
    }

    private func normalizedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        let result = FlashFileBrowserPathPolicy.standardized(url)
        guard !result.path.isEmpty else { return nil }
        return result
    }

    /// Serializes root binding independently of main-actor task reentrancy.
    /// A Swift actor processes one method at a time but does not promise FIFO
    /// ordering between different caller tasks; chaining requests here ensures
    /// the newest CWD is also the final root installed in the filesystem actor.
    private func enqueueRootBinding(_ root: URL) async -> String? {
        let predecessor = rootBindingTail
        let fileSystem = fileSystem
        pendingRootBindingCount += 1

        let binding = Task { @MainActor in
            if let predecessor {
                await predecessor.value
            }
            do {
                try await fileSystem.bindRoot(root)
                return nil as String?
            } catch {
                return error.localizedDescription
            }
        }
        rootBindingTail = Task { @MainActor in
            _ = await binding.value
        }

        let result = await binding.value
        pendingRootBindingCount -= 1
        return result
    }
}
