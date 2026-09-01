import Darwin
import Foundation

extension LocalFlashFileBrowserFileSystem {
    private static let maximumCopyDepth = 256
    private static let incompleteCopyPrefix = "FLASH Incomplete Copy "

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

    private func incompleteCopyName(
        for sourceName: String,
        in descriptor: Int32
    ) throws -> String {
        let maximumNameByteCount = Darwin.fpathconf(descriptor, _PC_NAME_MAX)
        guard maximumNameByteCount > 0 else {
            // Do not guess a fallback: a guessed limit could make a recovery
            // entry impossible to create on the actual destination volume.
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        let delimiter = " - "

        for _ in 0..<100 {
            // Failed or cancelled copies are deliberately visible in the file
            // browser so users can inspect and trash the partial payload. Keep
            // the original name's UTF-8-safe tail so its extension remains
            // recognizable by the type filter.
            let baseName = Self.incompleteCopyPrefix + UUID().uuidString
            guard baseName.utf8.count <= maximumNameByteCount else {
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }
            let suffixByteCount = maximumNameByteCount -
                baseName.utf8.count - delimiter.utf8.count
            let sourceSuffix = utf8Suffix(
                of: sourceName,
                maximumByteCount: suffixByteCount
            )
            let name = sourceSuffix.isEmpty
                ? baseName
                : baseName + delimiter + sourceSuffix
            if entryIdentity(named: name, in: descriptor) == nil {
                return name
            }
        }
        throw FlashFileBrowserFileSystemError.cannotPrepareCopy
    }

    private func utf8Suffix(
        of value: String,
        maximumByteCount: Int
    ) -> String {
        guard maximumByteCount > 0 else { return "" }
        var start = value.endIndex
        var usedByteCount = 0
        while start > value.startIndex {
            let candidateStart = value.index(before: start)
            let characterByteCount = value[candidateStart..<start].utf8.count
            guard usedByteCount + characterByteCount <= maximumByteCount else {
                break
            }
            usedByteCount += characterByteCount
            start = candidateStart
        }
        return String(value[start...])
    }

    private struct AnchoredDirectoryPathComponent {
        let name: String
        let identity: FlashFileBrowserItemIdentity
    }

    private func openAnchoredDirectoryPath(
        _ path: [AnchoredDirectoryPathComponent],
        rootDescriptor: Int32
    ) -> Int32? {
        var descriptor = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { return nil }

        for component in path {
            guard entryIdentity(named: component.name, in: descriptor) ==
                    component.identity else {
                Darwin.close(descriptor)
                return nil
            }
            let childDescriptor = openDirectoryEntry(
                named: component.name,
                expectedIdentity: component.identity,
                in: descriptor
            )
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

    private struct RootMetadataEntry {
        let descriptor: Int32
        let identity: FlashFileBrowserItemIdentity
        let mode: mode_t
    }

    private struct RootMetadataCommit {
        let source: RootMetadataEntry
        let destination: RootMetadataEntry
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

        // Copy the root directly into a random sibling entry. There is no
        // wrapper directory to clean up: failure and cancellation preserve the
        // visible partial entry, while success atomically renames this exact
        // staged identity to the final name with RENAME_EXCL.
        let stagedName = try incompleteCopyName(
            for: source.url.lastPathComponent,
            in: validated.descriptor
        )
        let stagedURL = validated.anchor.url
            .appendingPathComponent(stagedName)
            .standardizedFileURL
        try runMutationHook(.copyDestinationOpened, directory: stagedURL)

        let sourceName = source.entryName ?? source.url.lastPathComponent
        let stagedIdentity = try copyEntry(
            named: sourceName,
            expectedIdentity: source.identity,
            to: stagedName,
            context: CopyTraversalContext(
                sourceDescriptor: sourceDirectory.descriptor,
                destinationDescriptor: validated.descriptor,
                sourceURL: source.url,
                forbiddenDirectoryIdentities: [
                    validated.anchor.directoryIdentity,
                ],
                depth: 0
            )
        )

        try runMutationHook(.copyDestinationFinished, directory: stagedURL)
        try runMutationHook(.copySourceFinished, directory: source.url)
        try runMutationHook(.stagedCopyReady, directory: directory)
        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )
        guard entryIdentity(named: stagedName, in: validated.descriptor) ==
                stagedIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        try revalidateCopySource(source, directory: sourceDirectory)

        try Task.checkCancellation()
        // The root stage intentionally has only payload plus safe creation
        // defaults. Pin both exact roots before the exclusive rename; after
        // promotion, root metadata is copied only between these descriptors.
        // Path checks remain read-only, so a replacement can cause failure but
        // can never receive the source's flags, ACLs, or extended attributes.
        let rootMetadataCommit = try prepareRootMetadataCommit(
            sourceName: sourceName,
            sourceIdentity: source.identity,
            sourceParentDescriptor: sourceDirectory.descriptor,
            destinationName: stagedName,
            destinationIdentity: stagedIdentity,
            destinationParentDescriptor: validated.descriptor
        )
        defer {
            Darwin.close(rootMetadataCommit.destination.descriptor)
            Darwin.close(rootMetadataCommit.source.descriptor)
        }
        let promoteOutcome = stagedName.withCString { staged in
            destinationName.withCString { destination in
                callCapturingErrno {
                    Darwin.renameatx_np(
                        validated.descriptor,
                        staged,
                        validated.descriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        if promoteOutcome.result != 0 {
            if promoteOutcome.errorCode == EEXIST {
                throw FlashFileBrowserFileSystemError.itemAlreadyExists(destinationName)
            }
            throw posixError(promoteOutcome.errorCode)
        }
        let destinationURL = directory
            .appendingPathComponent(destinationName)
            .standardizedFileURL
        guard rootMetadataEntryIsCurrent(
                  rootMetadataCommit.source,
                  named: sourceName,
                  in: sourceDirectory.descriptor
              ),
              rootMetadataEntryIsCurrent(
                  rootMetadataCommit.destination,
                  named: destinationName,
                  in: validated.descriptor
              ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        try runMutationHook(.copyPromoted, directory: destinationURL)
        guard rootMetadataEntryIsCurrent(
                  rootMetadataCommit.source,
                  named: sourceName,
                  in: sourceDirectory.descriptor
              ),
              rootMetadataEntryIsCurrent(
                  rootMetadataCommit.destination,
                  named: destinationName,
                  in: validated.descriptor
              ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        let committedDestination = try commitRootMetadata(rootMetadataCommit)
        guard rootMetadataEntryIsCurrent(
                  rootMetadataCommit.source,
                  named: sourceName,
                  in: sourceDirectory.descriptor
              ),
              rootMetadataEntryIsCurrent(
                  committedDestination,
                  named: destinationName,
                  in: validated.descriptor
              ) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        try revalidateCopySource(source, directory: sourceDirectory)

        try revalidateDirectoryDescriptor(
            validated,
            directory: directory,
            allowedRoot: allowedRoot
        )

        return destinationURL
    }

    private func prepareRootMetadataCommit(
        sourceName: String,
        sourceIdentity: FlashFileBrowserItemIdentity,
        sourceParentDescriptor: Int32,
        destinationName: String,
        destinationIdentity: FlashFileBrowserItemIdentity,
        destinationParentDescriptor: Int32
    ) throws -> RootMetadataCommit {
        let source = try openRootMetadataEntry(
            named: sourceName,
            expectedIdentity: sourceIdentity,
            in: sourceParentDescriptor,
            writableRegularFile: false
        )
        do {
            let destination = try openRootMetadataEntry(
                named: destinationName,
                expectedIdentity: destinationIdentity,
                in: destinationParentDescriptor,
                writableRegularFile: true
            )
            guard source.mode == destination.mode,
                  rootMetadataEntryIsCurrent(
                      source,
                      named: sourceName,
                      in: sourceParentDescriptor
                  ),
                  rootMetadataEntryIsCurrent(
                      destination,
                      named: destinationName,
                      in: destinationParentDescriptor
                  ) else {
                Darwin.close(destination.descriptor)
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }
            return RootMetadataCommit(
                source: source,
                destination: destination
            )
        } catch {
            Darwin.close(source.descriptor)
            throw error
        }
    }

    private func openRootMetadataEntry(
        named name: String,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in parentDescriptor: Int32,
        writableRegularFile: Bool
    ) throws -> RootMetadataEntry {
        guard let initialMetadata = entryMetadata(named: name, in: parentDescriptor),
              identity(from: initialMetadata) == expectedIdentity else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        let entryMode = initialMetadata.st_mode & S_IFMT
        let openFlags: Int32
        switch entryMode {
        case S_IFREG:
            openFlags = (writableRegularFile ? O_WRONLY : O_RDONLY) |
                O_NOFOLLOW | O_RESOLVE_BENEATH | O_CLOEXEC
        case S_IFDIR:
            openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                O_RESOLVE_BENEATH | O_CLOEXEC
        case S_IFLNK:
            openFlags = O_RDONLY | O_SYMLINK | O_RESOLVE_BENEATH | O_CLOEXEC
        default:
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        let openOutcome = name.withCString { entryName in
            callCapturingErrno {
                Darwin.openat(parentDescriptor, entryName, openFlags)
            }
        }
        let descriptor = openOutcome.result
        guard descriptor >= 0 else { throw posixError(openOutcome.errorCode) }

        let entry = RootMetadataEntry(
            descriptor: descriptor,
            identity: expectedIdentity,
            mode: entryMode
        )
        guard rootMetadataEntryIsCurrent(
                  entry,
                  named: name,
                  in: parentDescriptor
              ) else {
            Darwin.close(descriptor)
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        return entry
    }

    private func commitRootMetadata(
        _ commit: RootMetadataCommit
    ) throws -> RootMetadataEntry {
        guard rootMetadataDescriptorIsCurrent(commit.source),
              rootMetadataDescriptorIsCurrent(commit.destination),
              commit.source.mode == commit.destination.mode else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        let copyOutcome = callCapturingErrno {
            Darwin.fcopyfile(
                commit.source.descriptor,
                commit.destination.descriptor,
                nil,
                copyfile_flags_t(COPYFILE_METADATA)
            )
        }
        guard copyOutcome.result == 0 else {
            throw posixError(copyOutcome.errorCode)
        }
        guard rootMetadataDescriptorIsCurrent(commit.source) else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        var destinationMetadata = stat()
        guard Darwin.fstat(
                  commit.destination.descriptor,
                  &destinationMetadata
              ) == 0,
              destinationMetadata.st_mode & S_IFMT == commit.destination.mode else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        let committedIdentity = identity(from: destinationMetadata)
        guard committedIdentity.device == commit.destination.identity.device,
              committedIdentity.inode == commit.destination.identity.inode,
              committedIdentity.generation == commit.destination.identity.generation else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }
        return RootMetadataEntry(
            descriptor: commit.destination.descriptor,
            identity: committedIdentity,
            mode: commit.destination.mode
        )
    }

    private func rootMetadataEntryIsCurrent(
        _ entry: RootMetadataEntry,
        named name: String,
        in parentDescriptor: Int32
    ) -> Bool {
        rootMetadataDescriptorIsCurrent(entry) &&
            entryIdentity(named: name, in: parentDescriptor) == entry.identity
    }

    private func rootMetadataDescriptorIsCurrent(
        _ entry: RootMetadataEntry
    ) -> Bool {
        var metadata = stat()
        return Darwin.fstat(entry.descriptor, &metadata) == 0 &&
            identity(from: metadata) == entry.identity &&
            metadata.st_mode & S_IFMT == entry.mode
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
                in: destinationParentDescriptor,
                copyMetadata: !entry.isRoot
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
                in: destinationParentDescriptor,
                copyMetadata: !entry.isRoot
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

        let createOutcome = entry.destinationName.withCString { destinationName in
            callCapturingErrno {
                Darwin.mkdirat(
                    destinationParentDescriptor,
                    destinationName,
                    mode_t(0o700)
                )
            }
        }
        guard createOutcome.result == 0 else {
            throw posixError(createOutcome.errorCode)
        }
        let openOutcome = entry.destinationName.withCString { destinationName in
            callCapturingErrno {
                Darwin.openat(
                    destinationParentDescriptor,
                    destinationName,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                        O_RESOLVE_BENEATH | O_CLOEXEC
                )
            }
        }
        let destinationDescriptor = openOutcome.result
        guard destinationDescriptor >= 0 else {
            throw posixError(openOutcome.errorCode)
        }
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

        // Root metadata is committed through retained descriptors only after
        // exclusive promotion. Nested entries can receive it while staged.
        if !entry.isRoot {
            let flags = copyfile_flags_t(COPYFILE_METADATA)
            let copyOutcome = callCapturingErrno {
                Darwin.fcopyfile(
                    sourceDescriptor,
                    destinationDescriptor,
                    nil,
                    flags
                )
            }
            guard copyOutcome.result == 0 else {
                throw posixError(copyOutcome.errorCode)
            }
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
        in destinationDescriptor: Int32,
        copyMetadata: Bool
    ) throws -> FlashFileBrowserItemIdentity {
        let sourceOutcome = sourceName.withCString { entryName in
            callCapturingErrno {
                Darwin.openat(
                    sourceDescriptor,
                    entryName,
                    O_RDONLY | O_NOFOLLOW | O_RESOLVE_BENEATH | O_CLOEXEC
                )
            }
        }
        let source = sourceOutcome.result
        guard source >= 0 else { throw posixError(sourceOutcome.errorCode) }
        defer { Darwin.close(source) }
        var sourceMetadata = stat()
        guard Darwin.fstat(source, &sourceMetadata) == 0,
              identity(from: sourceMetadata) == expectedIdentity,
              sourceMetadata.st_mode & S_IFMT == S_IFREG else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        let destinationOutcome = destinationName.withCString { entryName in
            callCapturingErrno {
                Darwin.openat(
                    destinationDescriptor,
                    entryName,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                        O_RESOLVE_BENEATH | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
        }
        let destination = destinationOutcome.result
        guard destination >= 0 else {
            throw posixError(destinationOutcome.errorCode)
        }
        defer { Darwin.close(destination) }
        // Root flags and ACLs must not make the visible stage hidden or
        // unmovable. They are applied after exclusive promotion instead.
        let flags = copyfile_flags_t(
            (copyMetadata ? COPYFILE_ALL : COPYFILE_DATA) |
                COPYFILE_DATA_SPARSE
        )
        let copyOutcome = callCapturingErrno {
            Darwin.fcopyfile(source, destination, nil, flags)
        }
        guard copyOutcome.result == 0 else {
            throw posixError(copyOutcome.errorCode)
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
        in destinationDescriptor: Int32,
        copyMetadata: Bool
    ) throws -> FlashFileBrowserItemIdentity {
        let sourceOutcome = sourceName.withCString { entryName in
            callCapturingErrno {
                Darwin.openat(
                    sourceDescriptor,
                    entryName,
                    O_RDONLY | O_SYMLINK | O_RESOLVE_BENEATH | O_CLOEXEC
                )
            }
        }
        let source = sourceOutcome.result
        guard source >= 0 else { throw posixError(sourceOutcome.errorCode) }
        defer { Darwin.close(source) }
        var sourceMetadata = stat()
        guard Darwin.fstat(source, &sourceMetadata) == 0,
              identity(from: sourceMetadata) == expectedIdentity,
              sourceMetadata.st_mode & S_IFMT == S_IFLNK else {
            throw FlashFileBrowserFileSystemError.cannotPrepareCopy
        }

        var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let readOutcome = target.withUnsafeMutableBufferPointer { buffer in
            callCapturingErrno {
                Darwin.freadlink(source, buffer.baseAddress!, buffer.count - 1)
            }
        }
        let targetLength = readOutcome.result
        guard targetLength >= 0 else { throw posixError(readOutcome.errorCode) }
        target[targetLength] = 0
        let createOutcome = target.withUnsafeBufferPointer { targetPointer in
            destinationName.withCString { destination in
                callCapturingErrno {
                    Darwin.symlinkat(
                        targetPointer.baseAddress!,
                        destinationDescriptor,
                        destination
                    )
                }
            }
        }
        guard createOutcome.result == 0 else {
            throw posixError(createOutcome.errorCode)
        }

        let destinationOutcome = destinationName.withCString { entryName in
            callCapturingErrno {
                Darwin.openat(
                    destinationDescriptor,
                    entryName,
                    O_RDONLY | O_SYMLINK | O_RESOLVE_BENEATH | O_CLOEXEC
                )
            }
        }
        let destination = destinationOutcome.result
        guard destination >= 0 else {
            throw posixError(destinationOutcome.errorCode)
        }
        defer { Darwin.close(destination) }
        // As with regular files and directories, defer root link metadata.
        if copyMetadata {
            let flags = copyfile_flags_t(COPYFILE_METADATA)
            let copyOutcome = callCapturingErrno {
                Darwin.fcopyfile(source, destination, nil, flags)
            }
            guard copyOutcome.result == 0 else {
                throw posixError(copyOutcome.errorCode)
            }
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
