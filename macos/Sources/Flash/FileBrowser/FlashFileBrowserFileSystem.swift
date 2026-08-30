import Darwin
import Foundation

/// Serializes local filesystem access away from the main/render thread.
actor LocalFlashFileBrowserFileSystem: FlashFileBrowserFileSystem {
    typealias TrashHandler = @Sendable (URL) throws -> Void
    typealias TrashDirectoryProvider = @Sendable (URL) throws -> URL
    typealias MutationHook = @Sendable (MutationCheckpoint, URL) throws -> Void

    enum MutationCheckpoint: Sendable {
        case directoryEntryRead
        case directoryOpened
        case directoryReadStarted
        case directoryReadFinished
        case copyDestinationOpened
        case copyDestinationFinished
        case copyEntryCopied
        case copySourceOpened
        case copySourceFinished
        case itemValidated
        case stagedCopyReady
        case trashDirectoryOpened
    }

    private let fileManager: FileManager
    private let maximumCopyNameAttempts: Int
    private let mutationHook: MutationHook?
    private let trashDirectoryProvider: TrashDirectoryProvider?
    private let trashHandler: TrashHandler?
    private var rootAnchor: DirectoryAnchor?
    /// A small navigation working set. Explicit navigation refreshes an
    /// entry, while ordinary reloads and mutations must match the identity
    /// already recorded for their path. The root entry is never evicted.
    private var directoryAnchors: [String: DirectoryAnchor] = [:]
    private var directoryAnchorRecency: [String] = []
    private let maximumDirectoryAnchorCount = 8
    private static let maximumCopyDepth = 256
    /// Cleanup starts at the temporary staging wrapper rather than the copied
    /// entry, so it needs one additional level to visit the deepest entry that
    /// the copy traversal can create.
    private static let maximumCopyCleanupDepth = maximumCopyDepth + 1
    private static let removalBlockingFlags = UInt32(
        UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND
    )

    private struct DirectoryAnchor: Equatable {
        let url: URL
        let entryIdentity: FlashFileBrowserItemIdentity
        let directoryIdentity: FlashFileBrowserItemIdentity
        let canonicalPath: String
    }

    init(
        fileManager: FileManager = .default,
        maximumCopyNameAttempts: Int = 100_000,
        mutationHook: MutationHook? = nil,
        trashDirectoryProvider: TrashDirectoryProvider? = nil,
        trashHandler: TrashHandler? = nil
    ) {
        self.fileManager = fileManager
        self.maximumCopyNameAttempts = max(1, maximumCopyNameAttempts)
        self.mutationHook = mutationHook
        self.trashDirectoryProvider = trashDirectoryProvider
        self.trashHandler = trashHandler
    }

    func bindRoot(_ root: URL) throws {
        guard let anchor = try directoryAnchor(at: root) else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }
        rootAnchor = anchor
        directoryAnchors = [anchor.url.path: anchor]
        directoryAnchorRecency = []
    }

    func isNavigationAllowed(
        _ directory: URL,
        allowedRoot: URL
    ) -> Bool {
        do {
            let anchor = try navigationAnchor(
                directory,
                allowedRoot: allowedRoot
            )
            rememberNavigationAnchor(anchor)
            return true
        } catch {
            return false
        }
    }

    func contents(
        of directory: URL,
        showingHiddenFiles: Bool,
        allowedRoot: URL
    ) throws -> [FlashFileBrowserItem] {
        let validated = try openValidatedDirectory(
            directory,
            allowedRoot: allowedRoot
        )
        defer { Darwin.close(validated.descriptor) }

        // A pathname can be replaced after validation. Enumerate a duplicate
        // of the validated directory descriptor so a transient symlink or
        // same-path replacement cannot disclose another directory's entries.
        try runMutationHook(.directoryReadStarted, directory: directory)
        let items = try directoryItems(
            in: validated.descriptor,
            directoryURL: validated.anchor.url,
            showingHiddenFiles: showingHiddenFiles
        )
        try runMutationHook(.directoryReadFinished, directory: directory)

        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        return items
    }

    func isHidden(
        _ item: URL,
        allowedRoot: URL
    ) -> Bool {
        guard FlashFileBrowserPathPolicy.contains(item, in: allowedRoot) else {
            return false
        }
        if item.lastPathComponent.hasPrefix(".") { return true }
        let directory = item.deletingLastPathComponent()
        guard FlashFileBrowserPathPolicy.isDirectChild(item, of: directory),
              let validated = try? openValidatedDirectory(
                  directory,
                  allowedRoot: allowedRoot
              ) else {
            return false
        }
        defer { Darwin.close(validated.descriptor) }

        guard let metadata = entryMetadata(
            named: item.lastPathComponent,
            in: validated.descriptor
        ) else {
            return false
        }
        return metadata.st_flags & UInt32(UF_HIDDEN) != 0
    }

    func createFolder(
        named name: String,
        in directory: URL,
        allowedRoot: URL
    ) throws -> URL {
        let destination = try destination(named: name, in: directory)
        let validated = try openValidatedDirectory(
            directory,
            allowedRoot: allowedRoot
        )
        defer { Darwin.close(validated.descriptor) }
        try runMutationHook(.directoryOpened, directory: directory)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )

        let result = name.withCString {
            Darwin.mkdirat(validated.descriptor, $0, mode_t(0o777))
        }
        if result != 0 {
            if errno == EEXIST {
                throw FlashFileBrowserFileSystemError.itemAlreadyExists(name)
            }
            throw currentPOSIXError()
        }

        guard let createdIdentity = entryIdentity(
            named: name,
            in: validated.descriptor
        ) else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }
        do {
            try revalidateDirectoryDescriptor(
                validated,
                directory: directory,
                allowedRoot: allowedRoot
            )
        } catch {
            if entryIdentity(named: name, in: validated.descriptor) == createdIdentity {
                _ = name.withCString {
                    Darwin.unlinkat(validated.descriptor, $0, AT_REMOVEDIR)
                }
            }
            throw error
        }
        return destination
    }

    func rename(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        to name: String,
        in directory: URL,
        allowedRoot: URL
    ) throws -> URL {
        let destination = try destination(named: name, in: directory)
        let sourceName = item.lastPathComponent
        guard FlashFileBrowserPathPolicy.isDirectChild(item, of: directory) else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        let validated = try openValidatedDirectory(
            directory,
            allowedRoot: allowedRoot
        )
        defer { Darwin.close(validated.descriptor) }
        try validateItem(
            item,
            expectedIdentity: expectedIdentity,
            in: directory,
            allowedRoot: allowedRoot,
            descriptor: validated.descriptor
        )
        guard destination != item.standardizedFileURL else { return destination }

        let destinationIdentity = entryIdentity(
            named: name,
            in: validated.descriptor
        )
        if let destinationIdentity {
            var isDistinctHardLink = false
            if destinationIdentity == expectedIdentity, name != sourceName {
                isDistinctHardLink = try containsLiteralEntry(
                    named: name,
                    in: validated.descriptor
                )
            }
            if destinationIdentity != expectedIdentity || isDistinctHardLink {
                throw FlashFileBrowserFileSystemError.itemAlreadyExists(
                    destination.lastPathComponent
                )
            }
        }

        try runMutationHook(.itemValidated, directory: directory)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        guard entryIdentity(named: sourceName, in: validated.descriptor) == expectedIdentity else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        let result = sourceName.withCString { source in
            name.withCString { target in
                if destinationIdentity == expectedIdentity {
                    Darwin.renameat(
                        validated.descriptor,
                        source,
                        validated.descriptor,
                        target
                    )
                } else {
                    Darwin.renameatx_np(
                        validated.descriptor,
                        source,
                        validated.descriptor,
                        target,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        if result != 0 {
            if errno == EEXIST {
                throw FlashFileBrowserFileSystemError.itemAlreadyExists(name)
            }
            throw currentPOSIXError()
        }

        guard entryIdentity(named: name, in: validated.descriptor) == expectedIdentity else {
            rollbackRename(
                from: name,
                to: sourceName,
                expectedIdentity: expectedIdentity,
                descriptor: validated.descriptor
            )
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }
        do {
            try revalidateDirectoryDescriptor(
                validated,
                directory: directory,
                allowedRoot: allowedRoot
            )
        } catch {
            rollbackRename(
                from: name,
                to: sourceName,
                expectedIdentity: expectedIdentity,
                descriptor: validated.descriptor
            )
            throw error
        }
        return destination
    }

    func duplicate(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in directory: URL,
        allowedRoot: URL
    ) throws -> URL {
        let validated = try openValidatedDirectory(
            directory,
            allowedRoot: allowedRoot
        )
        defer { Darwin.close(validated.descriptor) }
        try validateItem(
            item,
            expectedIdentity: expectedIdentity,
            in: directory,
            allowedRoot: allowedRoot,
            descriptor: validated.descriptor
        )
        let destinationName = try duplicateDestinationName(
            for: item,
            descriptor: validated.descriptor
        )
        return try stageAndPromoteCopy(
            source: CopySource(
                url: item,
                identity: expectedIdentity,
                entryName: item.lastPathComponent
            ),
            destinationName: destinationName,
            directory: directory,
            allowedRoot: allowedRoot,
            validated: validated
        )
    }

    func copyItem(
        _ source: URL,
        to directory: URL,
        allowedRoot: URL
    ) throws -> URL {
        let source = source.standardizedFileURL
        let sourceIdentity = itemIdentity(at: source)
        guard source.isFileURL,
              !source.lastPathComponent.isEmpty,
              let sourceIdentity else {
            throw FlashFileBrowserFileSystemError.copySourceUnavailable(
                source.lastPathComponent
            )
        }
        let validated = try openValidatedDirectory(
            directory,
            allowedRoot: allowedRoot
        )
        defer { Darwin.close(validated.descriptor) }
        let destinationName = try copyDestinationName(
            for: source,
            descriptor: validated.descriptor
        )
        return try stageAndPromoteCopy(
            source: CopySource(
                url: source,
                identity: sourceIdentity,
                entryName: nil
            ),
            destinationName: destinationName,
            directory: directory,
            allowedRoot: allowedRoot,
            validated: validated
        )
    }

    func moveToTrash(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in directory: URL,
        allowedRoot: URL
    ) throws {
        let validated = try openValidatedDirectory(
            directory,
            allowedRoot: allowedRoot
        )
        defer { Darwin.close(validated.descriptor) }
        try validateItem(
            item,
            expectedIdentity: expectedIdentity,
            in: directory,
            allowedRoot: allowedRoot,
            descriptor: validated.descriptor
        )
        try runMutationHook(.itemValidated, directory: directory)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        guard entryIdentity(named: item.lastPathComponent, in: validated.descriptor) ==
                expectedIdentity else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        // The injected handler is a test seam and intentionally observes the
        // original path without mutating it. Production uses anchored source
        // and same-volume Trash directory descriptors below.
        if let trashHandler {
            try trashHandler(item)
            return
        }

        let trash = try openTrashDirectory(
            appropriateFor: item,
            sourceDevice: expectedIdentity.device
        )
        defer { Darwin.close(trash.descriptor) }
        try runMutationHook(.trashDirectoryOpened, directory: trash.anchor.url)
        try revalidateExternalDirectoryDescriptor(trash)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        guard entryIdentity(named: item.lastPathComponent, in: validated.descriptor) ==
                expectedIdentity else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }
        let trashName = try trashDestinationName(
            for: item.lastPathComponent,
            descriptor: trash.descriptor
        )
        let moveResult = item.lastPathComponent.withCString { source in
            trashName.withCString { destination in
                Darwin.renameatx_np(
                    validated.descriptor,
                    source,
                    trash.descriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moveResult == 0 else {
            if errno == EEXIST {
                throw FlashFileBrowserFileSystemError.cannotPrepareTrash
            }
            throw currentPOSIXError()
        }
        guard entryIdentity(named: trashName, in: trash.descriptor) == expectedIdentity else {
            rollbackRename(
                from: trashName,
                sourceDescriptor: trash.descriptor,
                to: item.lastPathComponent,
                destinationDescriptor: validated.descriptor,
                expectedIdentity: expectedIdentity
            )
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        do {
            try revalidateDirectoryDescriptor(
                validated,
                directory: directory,
                allowedRoot: allowedRoot
            )
            try revalidateExternalDirectoryDescriptor(trash)
        } catch {
            rollbackRename(
                from: trashName,
                sourceDescriptor: trash.descriptor,
                to: item.lastPathComponent,
                destinationDescriptor: validated.descriptor,
                expectedIdentity: expectedIdentity,
            )
            throw error
        }
    }

    func moveToTrash(
        _ targets: [FlashFileBrowserMutationTarget],
        in directory: URL,
        allowedRoot: URL
    ) async throws {
        // Preflight the entire destructive batch before touching any entry.
        // Each entry is checked again immediately before Trash in case an
        // external process replaces it while an earlier item is moving.
        for target in targets {
            try validateItem(
                target.url,
                expectedIdentity: target.expectedIdentity,
                in: directory,
                allowedRoot: allowedRoot
            )
        }

        var completed = 0
        for target in targets {
            do {
                try moveToTrash(
                    target.url,
                    expectedIdentity: target.expectedIdentity,
                    in: directory,
                    allowedRoot: allowedRoot
                )
                completed += 1
            } catch {
                throw FlashFileBrowserFileSystemError.batchOperationFailed(
                    completed: completed,
                    total: targets.count,
                    reason: error.localizedDescription
                )
            }
        }
    }

    @discardableResult
    private func validateDirectory(
        _ directory: URL,
        allowedRoot: URL
    ) throws -> DirectoryAnchor {
        let root = FlashFileBrowserPathPolicy.standardized(allowedRoot)
        if rootAnchor == nil {
            try bindRoot(root)
        }
        guard let expectedRoot = rootAnchor,
              expectedRoot.url == root,
              try directoryAnchor(at: root) == expectedRoot else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }

        let normalizedDirectory = FlashFileBrowserPathPolicy.standardized(directory)
        guard FlashFileBrowserPathPolicy.contains(normalizedDirectory, in: root),
              FlashFileBrowserPathPolicy.containsResolved(normalizedDirectory, in: root) else {
            throw FlashFileBrowserFileSystemError.outsideWorkingDirectory
        }

        guard let currentAnchor = try directoryAnchor(at: normalizedDirectory) else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }
        guard containsCanonicalPath(currentAnchor, in: expectedRoot) else {
            throw FlashFileBrowserFileSystemError.outsideWorkingDirectory
        }
        guard let expected = directoryAnchors[normalizedDirectory.path],
              currentAnchor == expected else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }
        return currentAnchor
    }

    /// Rebinds only at an explicit navigation boundary. The root remains
    /// pinned, while the destination may legitimately be a newly-created
    /// directory at a path that was visited earlier.
    private func navigationAnchor(
        _ directory: URL,
        allowedRoot: URL
    ) throws -> DirectoryAnchor {
        let root = FlashFileBrowserPathPolicy.standardized(allowedRoot)
        if rootAnchor == nil {
            try bindRoot(root)
        }
        guard let expectedRoot = rootAnchor,
              expectedRoot.url == root,
              try directoryAnchor(at: root) == expectedRoot else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }

        let normalizedDirectory = FlashFileBrowserPathPolicy.standardized(directory)
        guard FlashFileBrowserPathPolicy.contains(normalizedDirectory, in: root),
              FlashFileBrowserPathPolicy.containsResolved(normalizedDirectory, in: root) else {
            throw FlashFileBrowserFileSystemError.outsideWorkingDirectory
        }
        guard let anchor = try directoryAnchor(at: normalizedDirectory),
              containsCanonicalPath(anchor, in: expectedRoot) else {
            throw FlashFileBrowserFileSystemError.outsideWorkingDirectory
        }
        if normalizedDirectory == root, anchor != expectedRoot {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }
        return anchor
    }

    private func rememberNavigationAnchor(_ anchor: DirectoryAnchor) {
        let path = anchor.url.path
        directoryAnchors[path] = anchor
        directoryAnchorRecency.removeAll { $0 == path }

        guard path != rootAnchor?.url.path else { return }
        directoryAnchorRecency.append(path)
        let maximumNonRootCount = maximumDirectoryAnchorCount - 1
        while directoryAnchorRecency.count > maximumNonRootCount {
            let evictedPath = directoryAnchorRecency.removeFirst()
            directoryAnchors.removeValue(forKey: evictedPath)
        }
    }

    private struct ValidatedDirectoryDescriptor {
        let descriptor: Int32
        let anchor: DirectoryAnchor
    }

    private struct ValidatedExternalDirectoryDescriptor {
        let descriptor: Int32
        let anchor: DirectoryAnchor
    }

    private func openValidatedDirectory(
        _ directory: URL,
        allowedRoot: URL
    ) throws -> ValidatedDirectoryDescriptor {
        let anchor = try validateDirectory(directory, allowedRoot: allowedRoot)
        let path = fileManager.fileSystemRepresentation(withPath: anchor.url.path)
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentPOSIXError() }

        do {
            let result = ValidatedDirectoryDescriptor(
                descriptor: descriptor,
                anchor: anchor
            )
            try revalidateDirectoryDescriptor(
                result,
                directory: directory,
                allowedRoot: allowedRoot
            )
            return result
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func revalidateDirectoryDescriptor(
        _ validated: ValidatedDirectoryDescriptor,
        directory: URL,
        allowedRoot: URL
    ) throws {
        guard let expectedRoot = rootAnchor else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }

        var initialMetadata = stat()
        guard Darwin.fstat(validated.descriptor, &initialMetadata) == 0,
              identity(from: initialMetadata) == validated.anchor.directoryIdentity,
              let initialPath = canonicalPath(for: validated.descriptor),
              initialPath == validated.anchor.canonicalPath,
              containsCanonicalPath(initialPath, in: expectedRoot.canonicalPath),
              try validateDirectory(directory, allowedRoot: allowedRoot) == validated.anchor else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }

        var finalMetadata = stat()
        guard Darwin.fstat(validated.descriptor, &finalMetadata) == 0,
              identity(from: finalMetadata) == validated.anchor.directoryIdentity,
              canonicalPath(for: validated.descriptor) == initialPath else {
            throw FlashFileBrowserFileSystemError.workingDirectoryChanged
        }
    }

    private func openTrashDirectory(
        appropriateFor item: URL,
        sourceDevice: UInt64
    ) throws -> ValidatedExternalDirectoryDescriptor {
        let trashURL: URL
        if let trashDirectoryProvider {
            trashURL = try trashDirectoryProvider(item)
        } else {
            trashURL = try fileManager.url(
                for: .trashDirectory,
                in: .userDomainMask,
                appropriateFor: item,
                create: true
            )
        }

        guard let anchor = try directoryAnchor(at: trashURL) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareTrash
        }
        let path = fileManager.fileSystemRepresentation(withPath: anchor.url.path)
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw FlashFileBrowserFileSystemError.cannotPrepareTrash
        }

        do {
            let result = ValidatedExternalDirectoryDescriptor(
                descriptor: descriptor,
                anchor: anchor
            )
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_uid == Darwin.geteuid(),
                  UInt64(truncatingIfNeeded: metadata.st_dev) == sourceDevice else {
                throw FlashFileBrowserFileSystemError.cannotPrepareTrash
            }
            try revalidateExternalDirectoryDescriptor(result)
            return result
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func revalidateExternalDirectoryDescriptor(
        _ validated: ValidatedExternalDirectoryDescriptor
    ) throws {
        var initialMetadata = stat()
        guard Darwin.fstat(validated.descriptor, &initialMetadata) == 0,
              identity(from: initialMetadata) == validated.anchor.directoryIdentity,
              canonicalPath(for: validated.descriptor) == validated.anchor.canonicalPath else {
            throw FlashFileBrowserFileSystemError.cannotPrepareTrash
        }

        var finalMetadata = stat()
        guard Darwin.fstat(validated.descriptor, &finalMetadata) == 0,
              identity(from: finalMetadata) == validated.anchor.directoryIdentity,
              canonicalPath(for: validated.descriptor) == validated.anchor.canonicalPath else {
            throw FlashFileBrowserFileSystemError.cannotPrepareTrash
        }
    }

    private func entryIdentity(
        named name: String,
        in descriptor: Int32
    ) -> FlashFileBrowserItemIdentity? {
        FlashFileBrowserDescriptorIO.entryIdentity(
            named: name,
            in: descriptor
        )
    }

    private func entryMetadata(
        named name: String,
        in descriptor: Int32,
        followingSymbolicLinks: Bool = false
    ) -> stat? {
        FlashFileBrowserDescriptorIO.entryMetadata(
            named: name,
            in: descriptor,
            followingSymbolicLinks: followingSymbolicLinks
        )
    }

    private func directoryItems(
        in descriptor: Int32,
        directoryURL: URL,
        showingHiddenFiles: Bool
    ) throws -> [FlashFileBrowserItem] {
        try FlashFileBrowserDirectoryReader.items(
            in: descriptor,
            directoryURL: directoryURL,
            showingHiddenFiles: showingHiddenFiles
        )
    }

    private func forEachDirectoryEntry(
        in descriptor: Int32,
        body: (String) throws -> Void
    ) throws {
        try FlashFileBrowserDescriptorIO.forEachDirectoryEntry(
            in: descriptor,
            body: body
        )
    }

    private func containsLiteralEntry(
        named expectedName: String,
        in descriptor: Int32
    ) throws -> Bool {
        var containsEntry = false
        try forEachDirectoryEntry(in: descriptor) { name in
            if name == expectedName {
                containsEntry = true
            }
        }
        return containsEntry
    }

    private func runMutationHook(
        _ checkpoint: MutationCheckpoint,
        directory: URL
    ) throws {
        try mutationHook?(checkpoint, directory)
    }

    private func currentPOSIXError() -> POSIXError {
        FlashFileBrowserDescriptorIO.currentPOSIXError()
    }

    private func validateItem(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in directory: URL,
        allowedRoot: URL,
        descriptor suppliedDescriptor: Int32? = nil
    ) throws {
        guard FlashFileBrowserPathPolicy.contains(item, in: allowedRoot) else {
            throw FlashFileBrowserFileSystemError.outsideWorkingDirectory
        }
        guard FlashFileBrowserPathPolicy.isDirectChild(item, of: directory) else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        let ownedDescriptor: ValidatedDirectoryDescriptor?
        if suppliedDescriptor == nil {
            ownedDescriptor = try openValidatedDirectory(
                directory,
                allowedRoot: allowedRoot
            )
        } else {
            ownedDescriptor = nil
        }
        defer {
            if let ownedDescriptor {
                Darwin.close(ownedDescriptor.descriptor)
            }
        }
        let descriptor = suppliedDescriptor ?? ownedDescriptor?.descriptor ?? -1
        guard entryIdentity(named: item.lastPathComponent, in: descriptor) == expectedIdentity else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }
    }

    private func rollbackRename(
        from sourceName: String,
        to destinationName: String,
        expectedIdentity: FlashFileBrowserItemIdentity?,
        descriptor: Int32
    ) {
        rollbackRename(
            from: sourceName,
            sourceDescriptor: descriptor,
            to: destinationName,
            destinationDescriptor: descriptor,
            expectedIdentity: expectedIdentity
        )
    }

    private func rollbackRename(
        from sourceName: String,
        sourceDescriptor: Int32,
        to destinationName: String,
        destinationDescriptor: Int32,
        expectedIdentity: FlashFileBrowserItemIdentity?
    ) {
        guard let expectedIdentity,
              entryIdentity(named: sourceName, in: sourceDescriptor) == expectedIdentity,
              entryIdentity(named: destinationName, in: destinationDescriptor) == nil else {
            return
        }
        _ = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    sourceDescriptor,
                    source,
                    destinationDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
    }

    private func destination(named name: String, in directory: URL) throws -> URL {
        guard isValidName(name) else {
            throw FlashFileBrowserFileSystemError.invalidName
        }
        return directory.appendingPathComponent(name).standardizedFileURL
    }

    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty &&
            name != "." &&
            name != ".." &&
            !name.contains("/") &&
            !name.contains(":") &&
            !name.contains("\0")
    }

    private func itemIdentity(at url: URL) -> FlashFileBrowserItemIdentity? {
        // `FileManager.attributesOfItem` also reads extended attributes on
        // recent macOS versions. A cloud-backed directory can block that work
        // indefinitely even though identity only needs the directory entry's
        // device and inode. `lstat` is both narrower and correct for symbolic
        // links because mutations act on the link itself, not its target.
        var metadata = stat()
        let path = fileManager.fileSystemRepresentation(withPath: url.path)
        guard Darwin.lstat(path, &metadata) == 0 else { return nil }

        return identity(from: metadata)
    }

    private func directoryAnchor(at url: URL) throws -> DirectoryAnchor? {
        let normalizedURL = FlashFileBrowserPathPolicy.standardized(url)
        var initialEntryMetadata = stat()
        let path = fileManager.fileSystemRepresentation(withPath: normalizedURL.path)
        guard Darwin.lstat(path, &initialEntryMetadata) == 0 else { return nil }
        let initialEntryIdentity = identity(from: initialEntryMetadata)

        try runMutationHook(.directoryEntryRead, directory: normalizedURL)

        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var initialDirectoryMetadata = stat()
        guard Darwin.fstat(descriptor, &initialDirectoryMetadata) == 0,
              let initialCanonicalPath = canonicalPath(for: descriptor) else {
            return nil
        }
        let initialDirectoryIdentity = identity(from: initialDirectoryMetadata)

        var finalEntryMetadata = stat()
        var finalDirectoryMetadata = stat()
        guard Darwin.lstat(path, &finalEntryMetadata) == 0,
              identity(from: finalEntryMetadata) == initialEntryIdentity,
              Darwin.fstat(descriptor, &finalDirectoryMetadata) == 0,
              identity(from: finalDirectoryMetadata) == initialDirectoryIdentity,
              canonicalPath(for: descriptor) == initialCanonicalPath else {
            return nil
        }

        return DirectoryAnchor(
            url: normalizedURL,
            entryIdentity: initialEntryIdentity,
            directoryIdentity: initialDirectoryIdentity,
            canonicalPath: initialCanonicalPath
        )
    }

    private func canonicalPath(for descriptor: Int32) -> String? {
        FlashFileBrowserDescriptorIO.canonicalPath(for: descriptor)
    }

    private func containsCanonicalPath(
        _ anchor: DirectoryAnchor,
        in root: DirectoryAnchor
    ) -> Bool {
        containsCanonicalPath(anchor.canonicalPath, in: root.canonicalPath)
    }

    private func containsCanonicalPath(
        _ candidatePath: String,
        in rootPath: String
    ) -> Bool {
        FlashFileBrowserDescriptorIO.containsCanonicalPath(
            candidatePath,
            in: rootPath
        )
    }

    private func identity(from metadata: stat) -> FlashFileBrowserItemIdentity {
        FlashFileBrowserDescriptorIO.identity(from: metadata)
    }

    private struct TemporaryCopyContainer {
        let name: String
        let url: URL
        let identity: FlashFileBrowserItemIdentity
        let descriptor: Int32
        let canonicalPath: String
    }

    private func createTemporaryCopyContainer(
        prefix: String,
        descriptor: Int32
    ) throws -> TemporaryCopyContainer {
        for _ in 0..<100 {
            let name = ".flash-ghostty-\(prefix)-\(UUID().uuidString)"
            let createResult = name.withCString {
                Darwin.mkdirat(descriptor, $0, mode_t(0o700))
            }
            if createResult != 0 {
                if errno == EEXIST { continue }
                throw currentPOSIXError()
            }

            guard let identity = entryIdentity(named: name, in: descriptor) else {
                _ = name.withCString {
                    Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR)
                }
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }
            let containerDescriptor = name.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard containerDescriptor >= 0 else {
                removeTemporaryDirectoryIfCurrent(
                    named: name,
                    identity: identity,
                    descriptor: descriptor
                )
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }

            var metadata = stat()
            guard Darwin.fstat(containerDescriptor, &metadata) == 0,
                  self.identity(from: metadata) == identity else {
                Darwin.close(containerDescriptor)
                removeTemporaryDirectoryIfCurrent(
                    named: name,
                    identity: identity,
                    descriptor: descriptor
                )
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathResult = pathBuffer.withUnsafeMutableBufferPointer {
                Darwin.fcntl(containerDescriptor, F_GETPATH, $0.baseAddress!)
            }
            guard pathResult == 0 else {
                Darwin.close(containerDescriptor)
                removeTemporaryDirectoryIfCurrent(
                    named: name,
                    identity: identity,
                    descriptor: descriptor
                )
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }

            return TemporaryCopyContainer(
                name: name,
                url: URL(fileURLWithPath: String(cString: pathBuffer), isDirectory: true),
                identity: identity,
                descriptor: containerDescriptor,
                canonicalPath: FlashFileBrowserPathPolicy.standardized(
                    URL(fileURLWithPath: String(cString: pathBuffer), isDirectory: true)
                ).path
            )
        }

        throw FlashFileBrowserFileSystemError.cannotPrepareCopy
    }

    private func removeTemporaryDirectoryIfCurrent(
        named name: String,
        identity: FlashFileBrowserItemIdentity,
        descriptor: Int32
    ) {
        guard entryIdentity(named: name, in: descriptor) == identity else { return }
        _ = name.withCString {
            Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR)
        }
    }

    private func removeTemporaryCopyContainer(
        _ container: TemporaryCopyContainer,
        descriptor: Int32
    ) {
        var metadata = stat()
        guard Darwin.fstat(container.descriptor, &metadata) == 0,
              identity(from: metadata) == container.identity,
              canonicalPath(for: container.descriptor) == container.canonicalPath,
              entryIdentity(named: container.name, in: descriptor) == container.identity else {
            return
        }
        removeDirectoryContents(
            in: container.descriptor,
            rootedAt: container.canonicalPath
        )
        guard canonicalPath(for: container.descriptor) == container.canonicalPath,
              entryIdentity(named: container.name, in: descriptor) == container.identity else {
            return
        }
        _ = container.name.withCString {
            Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR)
        }
    }

    private struct AnchoredDirectoryPathComponent {
        let name: String
        let identity: FlashFileBrowserItemIdentity
    }

    private struct TemporaryRemovalEntry {
        let name: String
        let identity: FlashFileBrowserItemIdentity
        let mode: mode_t
    }

    private enum TemporaryRemovalOperation {
        case visitDirectory(
            path: [AnchoredDirectoryPathComponent],
            depth: Int
        )
        case removeDirectory(
            parentPath: [AnchoredDirectoryPathComponent],
            entry: TemporaryRemovalEntry
        )
        case removeFile(
            parentPath: [AnchoredDirectoryPathComponent],
            entry: TemporaryRemovalEntry
        )
    }

    private func removeDirectoryContents(
        in descriptor: Int32,
        rootedAt rootPath: String
    ) {
        var operations: [TemporaryRemovalOperation] = [
            .visitDirectory(path: [], depth: 0),
        ]

        while let operation = operations.popLast() {
            switch operation {
            case let .visitDirectory(path, depth):
                guard depth < Self.maximumCopyCleanupDepth,
                      let entries = temporaryRemovalEntries(
                          in: path,
                          rootDescriptor: descriptor,
                          rootPath: rootPath
                      ) else { continue }

                for entry in entries.reversed() {
                    if entry.mode == S_IFDIR {
                        operations.append(
                            .removeDirectory(parentPath: path, entry: entry)
                        )
                        operations.append(
                            .visitDirectory(
                                path: path + [
                                    AnchoredDirectoryPathComponent(
                                        name: entry.name,
                                        identity: entry.identity
                                    ),
                                ],
                                depth: depth + 1
                            )
                        )
                    } else {
                        operations.append(
                            .removeFile(parentPath: path, entry: entry)
                        )
                    }
                }

            case let .removeDirectory(parentPath, entry):
                removeTemporaryDirectory(
                    entry,
                    parentPath: parentPath,
                    rootDescriptor: descriptor,
                    rootPath: rootPath
                )

            case let .removeFile(parentPath, entry):
                removeTemporaryFile(
                    entry,
                    parentPath: parentPath,
                    rootDescriptor: descriptor,
                    rootPath: rootPath
                )
            }
        }
    }

    private func temporaryRemovalEntries(
        in path: [AnchoredDirectoryPathComponent],
        rootDescriptor: Int32,
        rootPath: String
    ) -> [TemporaryRemovalEntry]? {
        guard let descriptor = openAnchoredDirectoryPath(
            path,
            rootDescriptor: rootDescriptor,
            preparingForRemoval: true
        ) else { return nil }
        defer { Darwin.close(descriptor) }

        guard let directoryPath = canonicalPath(for: descriptor),
              containsCanonicalPath(directoryPath, in: rootPath) else {
            return nil
        }

        var entries: [TemporaryRemovalEntry] = []
        do {
            try forEachDirectoryEntry(in: descriptor) { name in
                guard canonicalPath(for: descriptor) == directoryPath,
                      let metadata = entryMetadata(named: name, in: descriptor) else {
                    return
                }
                let entry = TemporaryRemovalEntry(
                    name: name,
                    identity: identity(from: metadata),
                    mode: metadata.st_mode & S_IFMT
                )
                if entry.mode == S_IFDIR {
                    guard let childDescriptor = openTemporaryEntryForRemoval(
                        named: name,
                        expectedIdentity: entry.identity,
                        expectedMode: S_IFDIR,
                        in: descriptor
                    ) else { return }
                    Darwin.close(childDescriptor)
                }
                entries.append(entry)
            }
        } catch {
            return nil
        }
        return entries
    }

    private func removeTemporaryDirectory(
        _ entry: TemporaryRemovalEntry,
        parentPath: [AnchoredDirectoryPathComponent],
        rootDescriptor: Int32,
        rootPath: String
    ) {
        guard let parentDescriptor = openAnchoredDirectoryPath(
            parentPath,
            rootDescriptor: rootDescriptor,
            preparingForRemoval: true
        ) else { return }
        defer { Darwin.close(parentDescriptor) }

        guard let parentCanonicalPath = canonicalPath(for: parentDescriptor),
              containsCanonicalPath(parentCanonicalPath, in: rootPath),
              entryIdentity(named: entry.name, in: parentDescriptor) == entry.identity else {
            return
        }
        _ = entry.name.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
    }

    private func removeTemporaryFile(
        _ entry: TemporaryRemovalEntry,
        parentPath: [AnchoredDirectoryPathComponent],
        rootDescriptor: Int32,
        rootPath: String
    ) {
        guard let parentDescriptor = openAnchoredDirectoryPath(
            parentPath,
            rootDescriptor: rootDescriptor,
            preparingForRemoval: true
        ) else { return }
        defer { Darwin.close(parentDescriptor) }

        guard let parentCanonicalPath = canonicalPath(for: parentDescriptor),
              containsCanonicalPath(parentCanonicalPath, in: rootPath),
              let metadata = entryMetadata(named: entry.name, in: parentDescriptor),
              identity(from: metadata) == entry.identity,
              metadata.st_mode & S_IFMT == entry.mode else {
            return
        }
        if metadata.st_flags & Self.removalBlockingFlags != 0 {
            guard let childDescriptor = openTemporaryEntryForRemoval(
                named: entry.name,
                expectedIdentity: entry.identity,
                expectedMode: entry.mode,
                in: parentDescriptor
            ) else { return }
            Darwin.close(childDescriptor)
        }
        guard entryIdentity(named: entry.name, in: parentDescriptor) == entry.identity else {
            return
        }
        _ = entry.name.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
    }

    private func openAnchoredDirectoryPath(
        _ path: [AnchoredDirectoryPathComponent],
        rootDescriptor: Int32,
        preparingForRemoval: Bool = false
    ) -> Int32? {
        var descriptor = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { return nil }

        for component in path {
            guard entryIdentity(named: component.name, in: descriptor) ==
                    component.identity else {
                Darwin.close(descriptor)
                return nil
            }
            let childDescriptor: Int32?
            if preparingForRemoval {
                childDescriptor = openTemporaryEntryForRemoval(
                    named: component.name,
                    expectedIdentity: component.identity,
                    expectedMode: S_IFDIR,
                    in: descriptor
                )
            } else {
                childDescriptor = openDirectoryEntry(
                    named: component.name,
                    expectedIdentity: component.identity,
                    in: descriptor
                )
            }
            guard let childDescriptor else {
                Darwin.close(descriptor)
                return nil
            }
            Darwin.close(descriptor)
            descriptor = childDescriptor
        }
        return descriptor
    }

    private func openDirectoryEntry(
        named name: String,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in descriptor: Int32
    ) -> Int32? {
        let entryDescriptor = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                    O_RESOLVE_BENEATH | O_CLOEXEC
            )
        }
        guard entryDescriptor >= 0 else { return nil }

        var metadata = stat()
        guard Darwin.fstat(entryDescriptor, &metadata) == 0,
              identity(from: metadata) == expectedIdentity,
              metadata.st_mode & S_IFMT == S_IFDIR,
              entryIdentity(named: name, in: descriptor) == expectedIdentity else {
            Darwin.close(entryDescriptor)
            return nil
        }
        return entryDescriptor
    }

    /// Copy metadata can make a fully staged entry read-only or immutable.
    /// Cleanup is limited to entries whose descriptor and parent name both
    /// still identify the app-created object.
    private func openTemporaryEntryForRemoval(
        named name: String,
        expectedIdentity: FlashFileBrowserItemIdentity,
        expectedMode: mode_t,
        in descriptor: Int32
    ) -> Int32? {
        let openFlags: Int32
        switch expectedMode {
        case S_IFDIR:
            openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                O_RESOLVE_BENEATH | O_CLOEXEC
        case S_IFREG:
            openFlags = O_RDONLY | O_NOFOLLOW | O_RESOLVE_BENEATH | O_CLOEXEC
        case S_IFLNK:
            openFlags = O_RDONLY | O_SYMLINK | O_RESOLVE_BENEATH | O_CLOEXEC
        default:
            return nil
        }

        let entryDescriptor = name.withCString {
            Darwin.openat(descriptor, $0, openFlags)
        }
        guard entryDescriptor >= 0 else { return nil }

        var metadata = stat()
        guard Darwin.fstat(entryDescriptor, &metadata) == 0,
              identity(from: metadata) == expectedIdentity,
              metadata.st_mode & S_IFMT == expectedMode else {
            Darwin.close(entryDescriptor)
            return nil
        }

        let blockingFlags = metadata.st_flags & Self.removalBlockingFlags
        if blockingFlags != 0,
           Darwin.fchflags(
               entryDescriptor,
               metadata.st_flags & ~Self.removalBlockingFlags
           ) != 0 {
            Darwin.close(entryDescriptor)
            return nil
        }

        if expectedMode == S_IFDIR {
            let currentPermissions = metadata.st_mode & mode_t(0o7777)
            let removalPermissions = currentPermissions | mode_t(0o700)
            if currentPermissions != removalPermissions,
               Darwin.fchmod(entryDescriptor, removalPermissions) != 0 {
                Darwin.close(entryDescriptor)
                return nil
            }
        }

        guard Darwin.fstat(entryDescriptor, &metadata) == 0,
              identity(from: metadata) == expectedIdentity,
              metadata.st_mode & S_IFMT == expectedMode,
              entryIdentity(named: name, in: descriptor) == expectedIdentity else {
            Darwin.close(entryDescriptor)
            return nil
        }
        return entryDescriptor
    }

    private func copyDestinationName(
        for source: URL,
        descriptor: Int32
    ) throws -> String {
        let preferred = source.lastPathComponent
        guard entryIdentity(named: preferred, in: descriptor) != nil else {
            return preferred
        }
        return try duplicateDestinationName(for: source, descriptor: descriptor)
    }

    private func trashDestinationName(
        for sourceName: String,
        descriptor: Int32
    ) throws -> String {
        if entryIdentity(named: sourceName, in: descriptor) == nil {
            return sourceName
        }

        let sourceURL = URL(fileURLWithPath: sourceName)
        let extensionName = sourceURL.pathExtension
        let baseName = extensionName.isEmpty
            ? sourceName
            : sourceURL.deletingPathExtension().lastPathComponent
        for attempt in 1...maximumCopyNameAttempts {
            let (index, overflow) = attempt.addingReportingOverflow(1)
            guard !overflow else { break }
            var candidateName = "\(baseName) \(index)"
            if !extensionName.isEmpty { candidateName += ".\(extensionName)" }
            if entryIdentity(named: candidateName, in: descriptor) == nil {
                return candidateName
            }
        }
        throw FlashFileBrowserFileSystemError.cannotPrepareTrash
    }

    private func duplicateDestinationName(
        for item: URL,
        descriptor: Int32
    ) throws -> String {
        let extensionName = item.pathExtension
        let baseName = extensionName.isEmpty
            ? item.lastPathComponent
            : item.deletingPathExtension().lastPathComponent

        for index in 1...maximumCopyNameAttempts {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            var candidateName = baseName + suffix
            if !extensionName.isEmpty { candidateName += ".\(extensionName)" }
            if entryIdentity(named: candidateName, in: descriptor) == nil {
                return candidateName
            }
        }

        throw FlashFileBrowserFileSystemError.cannotAllocateCopyName
    }

    private struct CopySource {
        let url: URL
        let identity: FlashFileBrowserItemIdentity
        let entryName: String?
    }

    private struct CopySourceDirectory {
        let descriptor: Int32
        let anchor: DirectoryAnchor
        let ownsDescriptor: Bool
    }

    private struct CopyTraversalContext {
        let sourceDescriptor: Int32
        let destinationDescriptor: Int32
        let sourceURL: URL
        let forbiddenDirectoryIdentities: Set<FlashFileBrowserItemIdentity>
        let depth: Int
    }

    private struct PendingCopyEntry {
        let sourceParentPath: [AnchoredDirectoryPathComponent]
        let destinationParentPath: [AnchoredDirectoryPathComponent]
        let sourceURL: URL
        let sourceName: String
        let destinationName: String
        let expectedIdentity: FlashFileBrowserItemIdentity
        let forbiddenDirectoryIdentities: Set<FlashFileBrowserItemIdentity>
        let depth: Int
        let isRoot: Bool
    }

    private struct PendingCopyDirectoryCompletion {
        let entry: PendingCopyEntry
        let destinationIdentity: FlashFileBrowserItemIdentity
    }

    private struct PreparedCopyDirectory {
        let completion: PendingCopyDirectoryCompletion
        let children: [PendingCopyEntry]
    }

    private enum PendingCopyOperation {
        case copyEntry(PendingCopyEntry)
        case finishDirectory(PendingCopyDirectoryCompletion)
    }

    private enum CopyEntryStep {
        case completed(FlashFileBrowserItemIdentity)
        case preparedDirectory(PreparedCopyDirectory)
    }

    private func stageAndPromoteCopy(
        source: CopySource,
        destinationName: String,
        directory: URL,
        allowedRoot: URL,
        validated: ValidatedDirectoryDescriptor
    ) throws -> URL {
        try Task.checkCancellation()
        try runMutationHook(.itemValidated, directory: directory)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        let sourceDirectory = try openCopySourceDirectory(
            for: source,
            validated: validated
        )
        defer {
            if sourceDirectory.ownsDescriptor {
                Darwin.close(sourceDirectory.descriptor)
            }
        }
        try runMutationHook(.copySourceOpened, directory: source.url)
        try revalidateCopySource(source, directory: sourceDirectory)
        try validateCopyTopology(
            source,
            sourceDescriptor: sourceDirectory.descriptor,
            destination: validated.anchor
        )

        let temporary = try createTemporaryCopyContainer(
            prefix: "copy",
            descriptor: validated.descriptor
        )
        defer {
            removeTemporaryCopyContainer(
                temporary,
                descriptor: validated.descriptor
            )
            Darwin.close(temporary.descriptor)
        }
        try runMutationHook(.copyDestinationOpened, directory: temporary.url)

        let stagedName = source.url.lastPathComponent
        let stagedIdentity = try copyEntry(
            named: source.entryName ?? stagedName,
            expectedIdentity: source.identity,
            to: stagedName,
            context: CopyTraversalContext(
                sourceDescriptor: sourceDirectory.descriptor,
                destinationDescriptor: temporary.descriptor,
                sourceURL: source.url,
                forbiddenDirectoryIdentities: [
                    validated.anchor.directoryIdentity,
                    temporary.identity,
                ],
                depth: 0
            )
        )

        try runMutationHook(.copyDestinationFinished, directory: temporary.url)
        try runMutationHook(.copySourceFinished, directory: source.url)
        try runMutationHook(.stagedCopyReady, directory: directory)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        guard entryIdentity(named: temporary.name, in: validated.descriptor) ==
                temporary.identity,
              canonicalPath(for: temporary.descriptor) == temporary.canonicalPath,
              entryIdentity(named: stagedName, in: temporary.descriptor) == stagedIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        try revalidateCopySource(source, directory: sourceDirectory)

        try Task.checkCancellation()
        let promoteResult = stagedName.withCString { staged in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    temporary.descriptor,
                    staged,
                    validated.descriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if promoteResult != 0 {
            if errno == EEXIST {
                throw FlashFileBrowserFileSystemError.itemAlreadyExists(destinationName)
            }
            throw currentPOSIXError()
        }
        guard entryIdentity(named: destinationName, in: validated.descriptor) == stagedIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        do {
            try revalidateDirectoryDescriptor(
                validated,
                directory: directory,
                allowedRoot: allowedRoot
            )
        } catch {
            rollbackRename(
                from: destinationName,
                sourceDescriptor: validated.descriptor,
                to: stagedName,
                destinationDescriptor: temporary.descriptor,
                expectedIdentity: stagedIdentity,
            )
            throw error
        }

        return directory.appendingPathComponent(destinationName).standardizedFileURL
    }

    private func openCopySourceDirectory(
        for source: CopySource,
        validated: ValidatedDirectoryDescriptor
    ) throws -> CopySourceDirectory {
        if source.entryName != nil {
            return CopySourceDirectory(
                descriptor: validated.descriptor,
                anchor: validated.anchor,
                ownsDescriptor: false
            )
        }

        let parent = FlashFileBrowserPathPolicy.standardized(
            source.url.deletingLastPathComponent()
        )
        guard FlashFileBrowserPathPolicy.isDirectChild(source.url, of: parent),
              let anchor = try directoryAnchor(at: parent) else {
            throw copySourceChangedError(source)
        }
        let path = fileManager.fileSystemRepresentation(withPath: anchor.url.path)
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw copySourceChangedError(source) }
        guard directoryDescriptor(descriptor, matches: anchor),
              entryIdentity(
                  named: source.url.lastPathComponent,
                  in: descriptor
              ) == source.identity else {
            Darwin.close(descriptor)
            throw copySourceChangedError(source)
        }
        return CopySourceDirectory(
            descriptor: descriptor,
            anchor: anchor,
            ownsDescriptor: true
        )
    }

    private func revalidateCopySource(
        _ source: CopySource,
        directory: CopySourceDirectory
    ) throws {
        guard directoryDescriptor(directory.descriptor, matches: directory.anchor),
              entryIdentity(
                  named: source.entryName ?? source.url.lastPathComponent,
                  in: directory.descriptor
              ) == source.identity else {
            throw copySourceChangedError(source)
        }
    }

    private func copySourceChangedError(
        _ source: CopySource
    ) -> FlashFileBrowserFileSystemError {
        if source.entryName == nil {
            return .copySourceUnavailable(source.url.lastPathComponent)
        }
        return .itemIsNotCurrent
    }

    private func directoryDescriptor(
        _ descriptor: Int32,
        matches anchor: DirectoryAnchor
    ) -> Bool {
        var initialMetadata = stat()
        guard Darwin.fstat(descriptor, &initialMetadata) == 0,
              identity(from: initialMetadata) == anchor.directoryIdentity,
              canonicalPath(for: descriptor) == anchor.canonicalPath else {
            return false
        }
        var finalMetadata = stat()
        return Darwin.fstat(descriptor, &finalMetadata) == 0 &&
            identity(from: finalMetadata) == anchor.directoryIdentity &&
            canonicalPath(for: descriptor) == anchor.canonicalPath
    }

    private func validateCopyTopology(
        _ source: CopySource,
        sourceDescriptor: Int32,
        destination: DirectoryAnchor
    ) throws {
        let sourceName = source.entryName ?? source.url.lastPathComponent
        guard let metadata = entryMetadata(named: sourceName, in: sourceDescriptor),
              identity(from: metadata) == source.identity else {
            throw copySourceChangedError(source)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return }

        let descriptor = sourceName.withCString {
            Darwin.openat(
                sourceDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_RESOLVE_BENEATH | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw copySourceChangedError(source) }
        defer { Darwin.close(descriptor) }
        var currentMetadata = stat()
        guard Darwin.fstat(descriptor, &currentMetadata) == 0,
              identity(from: currentMetadata) == source.identity,
              let sourcePath = canonicalPath(for: descriptor) else {
            throw copySourceChangedError(source)
        }
        if containsCanonicalPath(destination.canonicalPath, in: sourcePath) {
            throw FlashFileBrowserFileSystemError.cannotCopyIntoItself
        }
    }

    private func copyEntry(
        named sourceName: String,
        expectedIdentity: FlashFileBrowserItemIdentity,
        to destinationName: String,
        context: CopyTraversalContext
    ) throws -> FlashFileBrowserItemIdentity {
        var operations: [PendingCopyOperation] = [
            .copyEntry(
                PendingCopyEntry(
                    sourceParentPath: [],
                    destinationParentPath: [],
                    sourceURL: context.sourceURL,
                    sourceName: sourceName,
                    destinationName: destinationName,
                    expectedIdentity: expectedIdentity,
                    forbiddenDirectoryIdentities: context.forbiddenDirectoryIdentities,
                    depth: context.depth,
                    isRoot: true
                )
            ),
        ]
        var rootIdentity: FlashFileBrowserItemIdentity?

        while let operation = operations.popLast() {
            switch operation {
            case let .copyEntry(entry):
                switch try copyPendingEntry(
                    entry,
                    sourceRootDescriptor: context.sourceDescriptor,
                    destinationRootDescriptor: context.destinationDescriptor
                ) {
                case let .completed(identity):
                    if entry.isRoot { rootIdentity = identity }

                case let .preparedDirectory(directory):
                    operations.append(.finishDirectory(directory.completion))
                    for child in directory.children.reversed() {
                        operations.append(.copyEntry(child))
                    }
                }

            case let .finishDirectory(completion):
                let identity = try finishPendingCopyDirectory(
                    completion,
                    sourceRootDescriptor: context.sourceDescriptor,
                    destinationRootDescriptor: context.destinationDescriptor
                )
                if completion.entry.isRoot { rootIdentity = identity }
            }
        }

        guard let rootIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        return rootIdentity
    }

    private func copyPendingEntry(
        _ entry: PendingCopyEntry,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws -> CopyEntryStep {
        try Task.checkCancellation()
        guard entry.depth < Self.maximumCopyDepth,
              let sourceParentDescriptor = openAnchoredDirectoryPath(
                  entry.sourceParentPath,
                  rootDescriptor: sourceRootDescriptor
              ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        defer { Darwin.close(sourceParentDescriptor) }
        guard let destinationParentDescriptor = openAnchoredDirectoryPath(
            entry.destinationParentPath,
            rootDescriptor: destinationRootDescriptor
        ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        defer { Darwin.close(destinationParentDescriptor) }

        guard let metadata = entryMetadata(
                  named: entry.sourceName,
                  in: sourceParentDescriptor
              ),
              identity(from: metadata) == entry.expectedIdentity,
              entryIdentity(
                  named: entry.destinationName,
                  in: destinationParentDescriptor
              ) == nil else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        let destinationIdentity: FlashFileBrowserItemIdentity
        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            destinationIdentity = try copyRegularFile(
                named: entry.sourceName,
                from: sourceParentDescriptor,
                expectedIdentity: entry.expectedIdentity,
                to: entry.destinationName,
                in: destinationParentDescriptor
            )

        case S_IFDIR:
            guard !entry.forbiddenDirectoryIdentities.contains(entry.expectedIdentity) else {
                throw FlashFileBrowserFileSystemError.cannotCopyIntoItself
            }
            return .preparedDirectory(
                try prepareCopyDirectory(
                    entry,
                    sourceParentDescriptor: sourceParentDescriptor,
                    destinationParentDescriptor: destinationParentDescriptor
                )
            )

        case S_IFLNK:
            destinationIdentity = try copySymbolicLink(
                named: entry.sourceName,
                from: sourceParentDescriptor,
                expectedIdentity: entry.expectedIdentity,
                to: entry.destinationName,
                in: destinationParentDescriptor
            )

        default:
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        try finishCopiedEntry(
            entry,
            destinationIdentity: destinationIdentity,
            sourceParentDescriptor: sourceParentDescriptor,
            destinationParentDescriptor: destinationParentDescriptor
        )
        return .completed(destinationIdentity)
    }

    private func prepareCopyDirectory(
        _ entry: PendingCopyEntry,
        sourceParentDescriptor: Int32,
        destinationParentDescriptor: Int32
    ) throws -> PreparedCopyDirectory {
        guard let sourceDescriptor = openDirectoryEntry(
            named: entry.sourceName,
            expectedIdentity: entry.expectedIdentity,
            in: sourceParentDescriptor
        ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        defer { Darwin.close(sourceDescriptor) }

        let createResult = entry.destinationName.withCString {
            Darwin.mkdirat(destinationParentDescriptor, $0, mode_t(0o700))
        }
        guard createResult == 0 else { throw currentPOSIXError() }
        let destinationDescriptor = entry.destinationName.withCString {
            Darwin.openat(
                destinationParentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                    O_RESOLVE_BENEATH | O_CLOEXEC
            )
        }
        guard destinationDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(destinationDescriptor) }

        var destinationMetadata = stat()
        guard Darwin.fstat(destinationDescriptor, &destinationMetadata) == 0,
              destinationMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        let destinationIdentity = identity(from: destinationMetadata)
        guard entryIdentity(
                  named: entry.destinationName,
                  in: destinationParentDescriptor
              ) == destinationIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        let sourceComponent = AnchoredDirectoryPathComponent(
            name: entry.sourceName,
            identity: entry.expectedIdentity
        )
        let destinationComponent = AnchoredDirectoryPathComponent(
            name: entry.destinationName,
            identity: destinationIdentity
        )
        var children: [PendingCopyEntry] = []
        try forEachDirectoryEntry(in: sourceDescriptor) { name in
            try Task.checkCancellation()
            guard let childMetadata = entryMetadata(named: name, in: sourceDescriptor) else {
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }
            children.append(
                PendingCopyEntry(
                    sourceParentPath: entry.sourceParentPath + [sourceComponent],
                    destinationParentPath: entry.destinationParentPath + [
                        destinationComponent,
                    ],
                    sourceURL: entry.sourceURL.appendingPathComponent(name),
                    sourceName: name,
                    destinationName: name,
                    expectedIdentity: identity(from: childMetadata),
                    forbiddenDirectoryIdentities: entry.forbiddenDirectoryIdentities,
                    depth: entry.depth + 1,
                    isRoot: false
                )
            )
        }

        var sourceMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0,
              identity(from: sourceMetadata) == entry.expectedIdentity,
              entryIdentity(named: entry.sourceName, in: sourceParentDescriptor) ==
                entry.expectedIdentity,
              entryIdentity(named: entry.destinationName, in: destinationParentDescriptor) ==
                destinationIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        return PreparedCopyDirectory(
            completion: PendingCopyDirectoryCompletion(
                entry: entry,
                destinationIdentity: destinationIdentity
            ),
            children: children
        )
    }

    private func finishPendingCopyDirectory(
        _ completion: PendingCopyDirectoryCompletion,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws -> FlashFileBrowserItemIdentity {
        let entry = completion.entry
        try Task.checkCancellation()
        guard let sourceParentDescriptor = openAnchoredDirectoryPath(
            entry.sourceParentPath,
            rootDescriptor: sourceRootDescriptor
        ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        defer { Darwin.close(sourceParentDescriptor) }
        guard let destinationParentDescriptor = openAnchoredDirectoryPath(
            entry.destinationParentPath,
            rootDescriptor: destinationRootDescriptor
        ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        defer { Darwin.close(destinationParentDescriptor) }

        guard let sourceDescriptor = openDirectoryEntry(
            named: entry.sourceName,
            expectedIdentity: entry.expectedIdentity,
            in: sourceParentDescriptor
        ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        defer { Darwin.close(sourceDescriptor) }
        guard let destinationDescriptor = openDirectoryEntry(
            named: entry.destinationName,
            expectedIdentity: completion.destinationIdentity,
            in: destinationParentDescriptor
        ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        defer { Darwin.close(destinationDescriptor) }

        let flags = copyfile_flags_t(COPYFILE_METADATA)
        guard Darwin.fcopyfile(
            sourceDescriptor,
            destinationDescriptor,
            nil,
            flags
        ) == 0 else {
            throw currentPOSIXError()
        }
        try Task.checkCancellation()
        let destinationIdentity = try createdIdentity(
            descriptor: destinationDescriptor,
            expectedMode: S_IFDIR,
            named: entry.destinationName,
            in: destinationParentDescriptor
        )
        try finishCopiedEntry(
            entry,
            destinationIdentity: destinationIdentity,
            sourceParentDescriptor: sourceParentDescriptor,
            destinationParentDescriptor: destinationParentDescriptor
        )
        return destinationIdentity
    }

    private func finishCopiedEntry(
        _ entry: PendingCopyEntry,
        destinationIdentity: FlashFileBrowserItemIdentity,
        sourceParentDescriptor: Int32,
        destinationParentDescriptor: Int32
    ) throws {
        guard entryIdentity(named: entry.sourceName, in: sourceParentDescriptor) ==
                entry.expectedIdentity,
              entryIdentity(named: entry.destinationName, in: destinationParentDescriptor) ==
                destinationIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        try runMutationHook(.copyEntryCopied, directory: entry.sourceURL)
        try Task.checkCancellation()
        guard entryIdentity(named: entry.sourceName, in: sourceParentDescriptor) ==
                entry.expectedIdentity,
              entryIdentity(named: entry.destinationName, in: destinationParentDescriptor) ==
                destinationIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
    }

    private func copyRegularFile(
        named sourceName: String,
        from sourceDescriptor: Int32,
        expectedIdentity: FlashFileBrowserItemIdentity,
        to destinationName: String,
        in destinationDescriptor: Int32
    ) throws -> FlashFileBrowserItemIdentity {
        let source = sourceName.withCString {
            Darwin.openat(
                sourceDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_RESOLVE_BENEATH | O_CLOEXEC
            )
        }
        guard source >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(source) }
        var sourceMetadata = stat()
        guard Darwin.fstat(source, &sourceMetadata) == 0,
              identity(from: sourceMetadata) == expectedIdentity,
              sourceMetadata.st_mode & S_IFMT == S_IFREG else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        let destination = destinationName.withCString {
            Darwin.openat(
                destinationDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                    O_RESOLVE_BENEATH | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard destination >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(destination) }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_DATA_SPARSE)
        guard Darwin.fcopyfile(source, destination, nil, flags) == 0 else {
            throw currentPOSIXError()
        }
        try Task.checkCancellation()
        guard Darwin.fstat(source, &sourceMetadata) == 0,
              identity(from: sourceMetadata) == expectedIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        return try createdIdentity(
            descriptor: destination,
            expectedMode: S_IFREG,
            named: destinationName,
            in: destinationDescriptor
        )
    }

    private func copySymbolicLink(
        named sourceName: String,
        from sourceDescriptor: Int32,
        expectedIdentity: FlashFileBrowserItemIdentity,
        to destinationName: String,
        in destinationDescriptor: Int32
    ) throws -> FlashFileBrowserItemIdentity {
        let source = sourceName.withCString {
            Darwin.openat(
                sourceDescriptor,
                $0,
                O_RDONLY | O_SYMLINK | O_RESOLVE_BENEATH | O_CLOEXEC
            )
        }
        guard source >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(source) }
        var sourceMetadata = stat()
        guard Darwin.fstat(source, &sourceMetadata) == 0,
              identity(from: sourceMetadata) == expectedIdentity,
              sourceMetadata.st_mode & S_IFMT == S_IFLNK else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let targetLength = target.withUnsafeMutableBufferPointer {
            Darwin.freadlink(source, $0.baseAddress!, $0.count - 1)
        }
        guard targetLength >= 0 else { throw currentPOSIXError() }
        target[targetLength] = 0
        let createResult = target.withUnsafeBufferPointer { targetPointer in
            destinationName.withCString { destination in
                Darwin.symlinkat(
                    targetPointer.baseAddress!,
                    destinationDescriptor,
                    destination
                )
            }
        }
        guard createResult == 0 else { throw currentPOSIXError() }

        let destination = destinationName.withCString {
            Darwin.openat(
                destinationDescriptor,
                $0,
                O_RDONLY | O_SYMLINK | O_RESOLVE_BENEATH | O_CLOEXEC
            )
        }
        guard destination >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(destination) }
        let flags = copyfile_flags_t(COPYFILE_METADATA)
        guard Darwin.fcopyfile(source, destination, nil, flags) == 0 else {
            throw currentPOSIXError()
        }
        try Task.checkCancellation()
        guard Darwin.fstat(source, &sourceMetadata) == 0,
              identity(from: sourceMetadata) == expectedIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        return try createdIdentity(
            descriptor: destination,
            expectedMode: S_IFLNK,
            named: destinationName,
            in: destinationDescriptor
        )
    }

    /// Capture the identity from the descriptor we created, then prove that
    /// the parent directory still exposes that exact object under its staged
    /// name. Reading identity from the name alone would accept an object that
    /// replaced the staged entry after the descriptor-relative copy.
    private func createdIdentity(
        descriptor: Int32,
        expectedMode: mode_t,
        named name: String,
        in parentDescriptor: Int32
    ) throws -> FlashFileBrowserItemIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == expectedMode else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        let createdIdentity = identity(from: metadata)
        guard entryIdentity(named: name, in: parentDescriptor) == createdIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        return createdIdentity
    }
}
