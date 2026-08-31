import Foundation

extension FlashFileBrowserModel {
    func createFolder(named name: String) async {
        // A post-commit provenance check can fail after the final pathname is
        // already present. Always reload on create errors so the sidebar
        // converges with disk even when directory monitoring misses the event.
        await performOperation(reloadAfterError: true) { fileSystem, directory, root in
            _ = try await fileSystem.createFolder(
                named: name,
                in: directory,
                allowedRoot: root
            )
        }
    }

    func rename(_ item: FlashFileBrowserItem, to name: String) async {
        guard let item = currentItem(matching: item) else {
            present(FlashFileBrowserFileSystemError.itemIsNotCurrent)
            return
        }

        await performOperation(reloadAfterError: true) { fileSystem, directory, root in
            _ = try await fileSystem.rename(
                item.url,
                expectedIdentity: item.identity,
                to: name,
                in: directory,
                allowedRoot: root
            )
        }
    }

    func duplicate(_ item: FlashFileBrowserItem) async {
        guard let item = currentItem(matching: item) else {
            present(FlashFileBrowserFileSystemError.itemIsNotCurrent)
            return
        }

        await performOperation(reloadAfterError: true) { fileSystem, directory, root in
            _ = try await fileSystem.duplicate(
                item.url,
                expectedIdentity: item.identity,
                in: directory,
                allowedRoot: root
            )
        }
    }

    func paste(_ sourceURLs: [URL]) async {
        let sources = uniqueFileURLs(sourceURLs)
        guard !sources.isEmpty else {
            present(FlashFileBrowserModelError.nothingToPaste)
            return
        }

        await performOperation(reloadAfterError: true) { fileSystem, directory, root in
            var completed = 0
            for source in sources {
                do {
                    try Task.checkCancellation()
                    _ = try await fileSystem.copyItem(
                        source,
                        to: directory,
                        allowedRoot: root
                    )
                    completed += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw FlashFileBrowserFileSystemError.batchOperationFailed(
                        completed: completed,
                        total: sources.count,
                        reason: error.localizedDescription
                    )
                }
            }
        }
    }

    func moveToTrash(_ item: FlashFileBrowserItem) async {
        await moveToTrash([item])
    }

    func moveToTrash(_ candidates: [FlashFileBrowserItem]) async {
        guard let items = currentItems(matching: candidates),
              !items.isEmpty else {
            present(FlashFileBrowserFileSystemError.itemIsNotCurrent)
            return
        }

        let targets = items.map {
            FlashFileBrowserMutationTarget(
                url: $0.url,
                expectedIdentity: $0.identity
            )
        }
        await performOperation(reloadAfterError: true) { fileSystem, directory, root in
            try await fileSystem.moveToTrash(
                targets,
                in: directory,
                allowedRoot: root
            )
        }
    }

    private func currentItems(
        matching candidates: [FlashFileBrowserItem]
    ) -> [FlashFileBrowserItem]? {
        guard let currentDirectory else { return nil }
        let currentItemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        var itemIDs: Set<FlashFileBrowserItem.ID> = []
        var result: [FlashFileBrowserItem] = []

        for candidate in candidates where itemIDs.insert(candidate.id).inserted {
            guard FlashFileBrowserPathPolicy.isDirectChild(
                candidate.url,
                of: currentDirectory
            ), let item = currentItemsByID[candidate.id],
               item.identity == candidate.identity else { return nil }
            result.append(item)
        }
        return result
    }

    private func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var paths: Set<String> = []
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let standardized = url.standardizedFileURL
            guard paths.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    private func performOperation(
        reloadAfterError: Bool,
        _ operation: (
            any FlashFileBrowserFileSystem,
            URL,
            URL
        ) async throws -> Void
    ) async {
        guard !isPerformingOperation else { return }
        guard let sessionID = synchronizedSessionID,
              let directory = currentDirectory,
              let root = sessionRoot else {
            present(FlashFileBrowserModelError.workingDirectoryUnavailable)
            return
        }

        operationGeneration &+= 1
        let generation = operationGeneration
        isPerformingOperation = true
        errorMessage = nil

        defer {
            if generation == operationGeneration {
                isPerformingOperation = false
                startExternalReloadIfNeeded()
            }
        }

        do {
            try await operation(fileSystem, directory, root)
            _ = await reconcileAfterMutation(
                generation: generation,
                sessionID: sessionID,
                directory: directory,
                root: root
            )
        } catch is CancellationError {
            // A batch may have committed earlier entries before cancellation.
            // Reconcile the visible directory without surfacing cancellation
            // as a user-facing error.
            if reloadAfterError {
                _ = await reconcileAfterMutation(
                    generation: generation,
                    sessionID: sessionID,
                    directory: directory,
                    root: root
                )
            }
            return
        } catch {
            guard generation == operationGeneration,
                  sessionID == synchronizedSessionID,
                  directory == currentDirectory,
                  root == sessionRoot else { return }

            let message = error.localizedDescription
            if reloadAfterError {
                guard await reconcileAfterMutation(
                    generation: generation,
                    sessionID: sessionID,
                    directory: directory,
                    root: root
                ) else { return }
            }
            errorMessage = message
        }
    }

    private func reconcileAfterMutation(
        generation: UInt,
        sessionID: SessionWorkspace.SessionID,
        directory: URL,
        root: URL
    ) async -> Bool {
        // A caller cancellation must not cancel reconciliation: the mutation
        // may already have committed. An unstructured task gets a fresh
        // cancellation state while preserving MainActor serialization.
        let reconciliation = Task { @MainActor [weak self] in
            guard let self,
                  generation == self.operationGeneration,
                  sessionID == self.synchronizedSessionID,
                  directory == self.currentDirectory,
                  root == self.sessionRoot else { return false }

            // A mutation invalidates forward history even when it leaves the
            // current directory in place. This load includes every event
            // delivered before it, retaining only events that arrive while
            // reconciliation itself is in flight.
            self.forwardHistory.removeAll(keepingCapacity: true)
            self.externalReloadPending = false
            await self.reload()

            return generation == self.operationGeneration &&
                sessionID == self.synchronizedSessionID &&
                directory == self.currentDirectory &&
                root == self.sessionRoot
        }
        return await reconciliation.value
    }
}
