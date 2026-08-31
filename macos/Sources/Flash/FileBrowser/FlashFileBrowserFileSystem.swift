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
        case folderCreationReady
        case folderStagingIdentityCaptured
        case folderStaged
        case folderPromotionReady
        case folderPromoted
        case copyDestinationOpened
        case copyDestinationFinished
        case copyEntryCopied
        case copyPromoted
        case copySourceOpened
        case copySourceFinished
        case itemValidated
        case stagedCopyReady
        case trashDirectoryOpened
    }

    let fileManager: FileManager
    let maximumCopyNameAttempts: Int
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

    struct DirectoryAnchor: Equatable {
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

        try runMutationHook(.folderCreationReady, directory: destination)
        if entryIdentity(named: name, in: validated.descriptor) != nil {
            throw FlashFileBrowserFileSystemError.itemAlreadyExists(name)
        }
        // Descriptor pinning and empty-directory verification require read
        // access to the newly created mode. An unusual process umask or ACL
        // that denies the owner that access fails explicitly instead of
        // falling back to an unverifiable direct mkdir.
        let stagedFolder: TemporaryDirectoryContainer
        stagedFolder = try createTemporaryDirectoryContainer(
            options: .folder,
            descriptor: validated.descriptor,
            identityCaptured: { [self] stagedName in
                try runMutationHook(
                    .folderStagingIdentityCaptured,
                    directory: validated.anchor.url.appendingPathComponent(
                        stagedName,
                        isDirectory: true
                    )
                )
            }
        )
        defer { Darwin.close(stagedFolder.descriptor) }

        try runMutationHook(.folderStaged, directory: stagedFolder.url)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        guard entryIdentity(named: stagedFolder.name, in: validated.descriptor) ==
                stagedFolder.identity,
              canonicalPath(for: stagedFolder.descriptor) == stagedFolder.canonicalPath,
              try directoryIsEmpty(stagedFolder.descriptor) else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        // Darwin cannot condition rename on the source inode. Pinning the
        // same-parent, randomly named directory first preserves the target
        // parent's mkdir mode/umask and inherited ACL semantics. RENAME_EXCL
        // protects the final name, and postconditions prevent an unknown object
        // from being reported as a successful creation. A same-UID process can
        // still race the source between any identity check and pathname syscall;
        // Darwin offers no source-inode-conditional rename. We therefore never
        // attempt a pathname rollback after the final name has committed.
        try runMutationHook(.folderPromotionReady, directory: stagedFolder.url)
        let promoteOutcome = stagedFolder.name.withCString { stagedName in
            name.withCString { destinationName in
                callCapturingErrno {
                    Darwin.renameatx_np(
                        validated.descriptor,
                        stagedName,
                        validated.descriptor,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        if promoteOutcome.result != 0 {
            if promoteOutcome.errorCode == EEXIST {
                throw FlashFileBrowserFileSystemError.itemAlreadyExists(name)
            }
            if promoteOutcome.errorCode == ENOTSUP {
                throw FlashFileBrowserFileSystemError.cannotCreateFolderSafely
            }
            throw posixError(promoteOutcome.errorCode)
        }

        try runMutationHook(.folderPromoted, directory: destination)
        var metadata = stat()
        guard Darwin.fstat(stagedFolder.descriptor, &metadata) == 0,
              identity(from: metadata) == stagedFolder.identity,
              metadata.st_mode & S_IFMT == S_IFDIR,
              entryIdentity(named: name, in: validated.descriptor) ==
                stagedFolder.identity,
              try directoryIsEmpty(stagedFolder.descriptor) else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        guard try directoryIsEmpty(stagedFolder.descriptor),
              entryIdentity(named: name, in: validated.descriptor) ==
                stagedFolder.identity else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
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
        if let destinationIdentity,
           destinationIdentity != expectedIdentity {
            throw FlashFileBrowserFileSystemError.itemAlreadyExists(
                destination.lastPathComponent
            )
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

        // Darwin has no rename primitive conditioned on a source inode. This
        // is therefore the final preflight before the syscall; `RENAME_EXCL`
        // protects an unrelated destination and the postcondition rejects a
        // mismatched result. Never attempt a pathname rollback after commit:
        // its source could be replaced after any identity precheck.
        let outcome = sourceName.withCString { source in
            name.withCString { target in
                callCapturingErrno {
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
        if outcome.result != 0 {
            if outcome.errorCode == EEXIST {
                throw FlashFileBrowserFileSystemError.itemAlreadyExists(name)
            }
            throw posixError(outcome.errorCode)
        }

        guard entryIdentity(named: name, in: validated.descriptor) == expectedIdentity else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        return destination
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
        // As with rename, Darwin cannot make source identity a syscall
        // precondition. The exclusive destination and postcondition prevent
        // overwrites. A post-commit failure is never rolled back by pathname,
        // because the source could be replaced between a check and rollback.
        let trashName = try trashDestinationName(
            for: item.lastPathComponent,
            descriptor: trash.descriptor
        )
        let moveOutcome = item.lastPathComponent.withCString { source in
            trashName.withCString { destination in
                callCapturingErrno {
                    Darwin.renameatx_np(
                        validated.descriptor,
                        source,
                        trash.descriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard moveOutcome.result == 0 else {
            if moveOutcome.errorCode == EEXIST {
                throw FlashFileBrowserFileSystemError.cannotPrepareTrash
            }
            throw posixError(moveOutcome.errorCode)
        }
        guard entryIdentity(named: trashName, in: trash.descriptor) == expectedIdentity else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        try revalidateExternalDirectoryDescriptor(trash)
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
            try Task.checkCancellation()
            try validateItem(
                target.url,
                expectedIdentity: target.expectedIdentity,
                in: directory,
                allowedRoot: allowedRoot
            )
        }

        var completed = 0
        for target in targets {
            try Task.checkCancellation()
            do {
                try moveToTrash(
                    target.url,
                    expectedIdentity: target.expectedIdentity,
                    in: directory,
                    allowedRoot: allowedRoot
                )
                completed += 1
            } catch let error as CancellationError {
                throw error
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

    struct ValidatedDirectoryDescriptor {
        let descriptor: Int32
        let anchor: DirectoryAnchor
    }

    private struct ValidatedExternalDirectoryDescriptor {
        let descriptor: Int32
        let anchor: DirectoryAnchor
    }

    func openValidatedDirectory(
        _ directory: URL,
        allowedRoot: URL
    ) throws -> ValidatedDirectoryDescriptor {
        let anchor = try validateDirectory(directory, allowedRoot: allowedRoot)
        let path = fileManager.fileSystemRepresentation(withPath: anchor.url.path)
        let openOutcome = callCapturingErrno {
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        let descriptor = openOutcome.result
        guard descriptor >= 0 else {
            throw posixError(openOutcome.errorCode)
        }

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

    func revalidateDirectoryDescriptor(
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

    func entryIdentity(
        named name: String,
        in descriptor: Int32
    ) -> FlashFileBrowserItemIdentity? {
        FlashFileBrowserDescriptorIO.entryIdentity(
            named: name,
            in: descriptor
        )
    }

    func entryMetadata(
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

    func forEachDirectoryEntry(
        in descriptor: Int32,
        body: (String) throws -> Void
    ) throws {
        try FlashFileBrowserDescriptorIO.forEachDirectoryEntry(
            in: descriptor,
            body: body
        )
    }

    private func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
        var isEmpty = true
        try forEachDirectoryEntry(in: descriptor) { _ in
            isEmpty = false
        }
        return isEmpty
    }

    func runMutationHook(
        _ checkpoint: MutationCheckpoint,
        directory: URL
    ) throws {
        try mutationHook?(checkpoint, directory)
    }

    func posixError(_ errorCode: Int32) -> POSIXError {
        FlashFileBrowserDescriptorIO.posixError(errorCode)
    }

    @inline(__always)
    func callCapturingErrno<Result>(
        _ operation: () -> Result
    ) -> (result: Result, errorCode: Int32) {
        FlashFileBrowserDescriptorIO.callCapturingErrno(operation)
    }

    func validateItem(
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

    func itemIdentity(at url: URL) -> FlashFileBrowserItemIdentity? {
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

    func directoryAnchor(at url: URL) throws -> DirectoryAnchor? {
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

    func canonicalPath(for descriptor: Int32) -> String? {
        FlashFileBrowserDescriptorIO.canonicalPath(for: descriptor)
    }

    private func containsCanonicalPath(
        _ anchor: DirectoryAnchor,
        in root: DirectoryAnchor
    ) -> Bool {
        containsCanonicalPath(anchor.canonicalPath, in: root.canonicalPath)
    }

    func containsCanonicalPath(
        _ candidatePath: String,
        in rootPath: String
    ) -> Bool {
        FlashFileBrowserDescriptorIO.containsCanonicalPath(
            candidatePath,
            in: rootPath
        )
    }

    func identity(from metadata: stat) -> FlashFileBrowserItemIdentity {
        FlashFileBrowserDescriptorIO.identity(from: metadata)
    }

    private struct TemporaryDirectoryContainer {
        let name: String
        let url: URL
        let identity: FlashFileBrowserItemIdentity
        let descriptor: Int32
        let canonicalPath: String
    }

    private struct TemporaryDirectoryCreationOptions {
        let prefix: String
        let mode: mode_t
        let preparationError: FlashFileBrowserFileSystemError
        let identityMismatchError: FlashFileBrowserFileSystemError

        static let folder = Self(
            prefix: "folder",
            mode: mode_t(0o777),
            preparationError: .cannotCreateFolderSafely,
            identityMismatchError: .itemIsNotCurrent
        )
    }

    private func createTemporaryDirectoryContainer(
        options: TemporaryDirectoryCreationOptions,
        descriptor: Int32,
        identityCaptured: ((String) throws -> Void)? = nil
    ) throws -> TemporaryDirectoryContainer {
        for _ in 0..<100 {
            let name = ".flash-ghostty-\(options.prefix)-\(UUID().uuidString)"
            let createOutcome = name.withCString { entryName in
                callCapturingErrno {
                    Darwin.mkdirat(descriptor, entryName, options.mode)
                }
            }
            if createOutcome.result != 0 {
                if createOutcome.errorCode == EEXIST { continue }
                throw posixError(createOutcome.errorCode)
            }

            guard let identity = entryIdentity(named: name, in: descriptor) else {
                // No trustworthy identity means cleanup could remove a
                // concurrent replacement. Leave the unpredictable orphan for
                // inspection instead of deleting unknown data.
                throw options.identityMismatchError
            }
            do {
                try identityCaptured?(name)
            } catch {
                throw error
            }
            let openOutcome = name.withCString { entryName in
                callCapturingErrno {
                    Darwin.openat(
                        descriptor,
                        entryName,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                            O_RESOLVE_BENEATH | O_CLOEXEC
                    )
                }
            }
            let containerDescriptor = openOutcome.result
            guard containerDescriptor >= 0 else {
                switch openOutcome.errorCode {
                case ENOENT, ELOOP, ENOTDIR:
                    throw options.identityMismatchError
                default:
                    throw options.preparationError
                }
            }

            var metadata = stat()
            guard Darwin.fstat(containerDescriptor, &metadata) == 0,
                  self.identity(from: metadata) == identity else {
                Darwin.close(containerDescriptor)
                throw options.identityMismatchError
            }

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathResult = pathBuffer.withUnsafeMutableBufferPointer {
                Darwin.fcntl(containerDescriptor, F_GETPATH, $0.baseAddress!)
            }
            guard pathResult == 0 else {
                Darwin.close(containerDescriptor)
                throw options.preparationError
            }

            return TemporaryDirectoryContainer(
                name: name,
                url: URL(fileURLWithPath: String(cString: pathBuffer), isDirectory: true),
                identity: identity,
                descriptor: containerDescriptor,
                canonicalPath: FlashFileBrowserPathPolicy.standardized(
                    URL(fileURLWithPath: String(cString: pathBuffer), isDirectory: true)
                ).path
            )
        }

        throw options.preparationError
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

}
