import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserFileSystemTests {
    @Test
    func contentsReadsItemsAndTreatsPackagesAsFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeDirectory(named: "Folder 10", in: root)
        try makeDirectory(named: "Folder 2", in: root)
        try makeFile(named: "File 10.txt", contents: "ten", in: root)
        try makeFile(named: "File 2.txt", contents: "two", in: root)
        let package = try makeApplicationPackage(named: "Application.app", in: root)

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let items = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )

        #expect(Set(items.map { $0.url.lastPathComponent }) == Set([
            "Folder 2",
            "Folder 10",
            "Application.app",
            "File 2.txt",
            "File 10.txt",
        ]))

        let packageItem = try #require(items.first { $0.url == package.standardizedFileURL })
        #expect(packageItem.isDirectory)
        #expect(packageItem.isPackage)
        #expect(!packageItem.isNavigableFolder)
    }

    @Test
    func contentsPreservesLiteralSpecialFileNames() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [
            "has space.txt",
            "résumé.swift",
            "hash#tag.md",
            "percent%name.json",
            "..not-a-parent",
            ".hidden",
        ]
        for name in names {
            try makeFile(named: name, contents: name, in: root)
        }

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let items = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: true,
            allowedRoot: root
        )

        #expect(Set(items.map(\.name)) == Set(names))
        for item in items {
            #expect(
                item.url.path == root
                    .appendingPathComponent(item.name)
                    .standardizedFileURL
                    .path
            )
        }
    }

    @Test
    func contentsEnumeratesTenThousandRealFilesystemEntries() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryCount = 10_000
        let fileManager = FileManager.default

        // Empty, non-atomic files keep this a real directory enumeration while
        // avoiding duplicate temporary-file writes during fixture creation.
        for index in 0..<entryCount {
            let url = root.appendingPathComponent("entry-\(index).txt")
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: nil
            ) else {
                throw POSIXError(.EIO)
            }
        }

        let items = try await LocalFlashFileBrowserFileSystem().contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )
        let names = Set(items.map(\.name))

        #expect(items.count == entryCount)
        #expect(names.count == entryCount)
        #expect(names.contains("entry-0.txt"))
        #expect(names.contains("entry-9999.txt"))
        #expect(Set(items.map(\.id)).count == entryCount)
        #expect(items.allSatisfy { item in
            !item.isDirectory &&
                !item.isHidden &&
                item.url.deletingLastPathComponent() == root
        })
    }

    @Test
    func contentsStopsAQueuedLargeDirectoryReadAfterCancellation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<300 {
            try makeFile(named: "file-\(index)", contents: "", in: root)
        }

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let read = Task {
            try await fileSystem.contents(
                of: root,
                showingHiddenFiles: false,
                allowedRoot: root
            )
        }
        read.cancel()

        do {
            _ = try await read.value
            Issue.record("Expected the cancelled directory read to stop")
        } catch is CancellationError {
            // Expected once enumeration reaches its bounded cancellation check.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func contentsFilterHiddenItemsUnlessRequested() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeFile(named: "visible.txt", contents: "visible", in: root)
        try makeFile(named: ".hidden.txt", contents: "hidden", in: root)
        try makeDirectory(named: ".hidden-folder", in: root)

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let visibleItems = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )
        let allItems = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: true,
            allowedRoot: root
        )

        #expect(visibleItems.map { $0.url.lastPathComponent } == ["visible.txt"])
        #expect(
            Set(allItems.map { $0.url.lastPathComponent }) == Set([
                "visible.txt",
                ".hidden.txt",
                ".hidden-folder",
            ])
        )
        let hiddenFlags = allItems
            .filter { $0.url.lastPathComponent.hasPrefix(".") }
            .map(\.isHidden)
        #expect(hiddenFlags == [true, true])
    }

    @Test
    func contentsCannotLeakFromRetargetedAncestorPath() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(named: "Root", in: container)
        let insideParent = try makeDirectory(named: "Inside", in: root)
        let outsideParent = try makeDirectory(named: "Outside", in: container)
        let insideProject = try makeDirectory(named: "Project", in: insideParent)
        let outsideProject = try makeDirectory(named: "Project", in: outsideParent)
        _ = try makeFile(named: "inside.txt", contents: "inside", in: insideProject)
        _ = try makeFile(
            named: "outside-secret.txt",
            contents: "secret",
            in: outsideProject
        )
        let parentLink = root.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: insideParent
        )
        let lexicalDirectory = parentLink.appendingPathComponent("Project")
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                switch checkpoint {
                case .directoryReadStarted:
                    try FileManager.default.removeItem(at: parentLink)
                    try FileManager.default.createSymbolicLink(
                        at: parentLink,
                        withDestinationURL: outsideParent
                    )
                case .directoryReadFinished:
                    try FileManager.default.removeItem(at: parentLink)
                    try FileManager.default.createSymbolicLink(
                        at: parentLink,
                        withDestinationURL: insideParent
                    )
                default:
                    break
                }
            }
        )

        try await fileSystem.bindRoot(root)
        #expect(await fileSystem.isNavigationAllowed(
            lexicalDirectory,
            allowedRoot: root
        ))

        let items = try await fileSystem.contents(
            of: lexicalDirectory,
            showingHiddenFiles: false,
            allowedRoot: root
        )

        #expect(items.map(\.name) == ["inside.txt"])
        #expect(!items.contains { $0.name == "outside-secret.txt" })
    }

    @Test
    func createFolderCreatesOneDirectChild() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let created = try await fileSystem.createFolder(
            named: "New Folder",
            in: root,
            allowedRoot: root
        )

        var isDirectory = ObjCBool(false)
        #expect(
            created.path == root
                .appendingPathComponent("New Folder", isDirectory: true)
                .standardizedFileURL
                .path
        )
        #expect(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test
    func renameMovesCurrentItemAndPreservesContents() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try makeFile(
            named: "before.txt",
            contents: "preserved",
            in: root
        )
        let fileSystem = LocalFlashFileBrowserFileSystem()
        let renamed = try await fileSystem.rename(
            original,
            expectedIdentity: try itemIdentity(at: original),
            to: "after.txt",
            in: root,
            allowedRoot: root
        )

        #expect(renamed == root.appendingPathComponent("after.txt").standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        try #expect(String(contentsOf: renamed, encoding: .utf8) == "preserved")
    }

    @Test
    func renameSupportsCaseOnlyNameChangesWithoutOverwriting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try makeFile(
            named: "report.txt",
            contents: "preserved",
            in: root
        )
        let fileSystem = LocalFlashFileBrowserFileSystem()
        let renamed = try await fileSystem.rename(
            original,
            expectedIdentity: try itemIdentity(at: original),
            to: "Report.txt",
            in: root,
            allowedRoot: root
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names == ["Report.txt"])
        try #expect(String(contentsOf: renamed, encoding: .utf8) == "preserved")
    }

    @Test
    func renameRejectsDistinctHardLinkWithSameIdentity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try makeFile(
            named: "before.txt",
            contents: "preserved",
            in: root
        )
        let hardLink = root.appendingPathComponent("after.txt")
        try FileManager.default.linkItem(at: original, to: hardLink)
        let fileSystem = LocalFlashFileBrowserFileSystem()

        #expect(try itemIdentity(at: original) == itemIdentity(at: hardLink))
        await expectFileSystemError(.itemAlreadyExists("after.txt")) {
            _ = try await fileSystem.rename(
                original,
                expectedIdentity: try itemIdentity(at: original),
                to: "after.txt",
                in: root,
                allowedRoot: root
            )
        }

        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == [
            "before.txt",
            "after.txt",
        ])
        try #expect(String(contentsOf: original, encoding: .utf8) == "preserved")
        try #expect(String(contentsOf: hardLink, encoding: .utf8) == "preserved")
    }

    @Test
    func duplicateUsesFinderStyleConflictNamesForFilesAndDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeFile(named: "Report.txt", contents: "report", in: root)
        _ = try makeFile(named: "Report copy.txt", contents: "existing", in: root)
        let folder = try makeDirectory(named: "Sources", in: root)
        _ = try makeFile(named: "child.swift", contents: "let value = 1", in: folder)

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let fileCopy = try await fileSystem.duplicate(
            source,
            expectedIdentity: try itemIdentity(at: source),
            in: root,
            allowedRoot: root
        )
        let folderCopy = try await fileSystem.duplicate(
            folder,
            expectedIdentity: try itemIdentity(at: folder),
            in: root,
            allowedRoot: root
        )

        #expect(fileCopy.lastPathComponent == "Report copy 2.txt")
        try #expect(String(contentsOf: fileCopy, encoding: .utf8) == "report")
        #expect(folderCopy.lastPathComponent == "Sources copy")
        try #expect(
            String(
                contentsOf: folderCopy.appendingPathComponent("child.swift"),
                encoding: .utf8
            ) == "let value = 1"
        )
    }

    @Test
    func duplicateNameExhaustionReturnsAnErrorInsteadOfCrashing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeFile(named: "Report.txt", contents: "source", in: root)
        _ = try makeFile(named: "Report copy.txt", contents: "first", in: root)
        _ = try makeFile(named: "Report copy 2.txt", contents: "second", in: root)
        let fileSystem = LocalFlashFileBrowserFileSystem(maximumCopyNameAttempts: 2)

        await expectFileSystemError(.cannotAllocateCopyName) {
            _ = try await fileSystem.duplicate(
                source,
                expectedIdentity: try itemIdentity(at: source),
                in: root,
                allowedRoot: root
            )
        }

        try #expect(String(contentsOf: source, encoding: .utf8) == "source")
    }

    @Test(arguments: ["", ".", "..", "nested/name", "colon:name", "null\0name"])
    func rejectsInvalidNames(_ name: String) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try makeFile(named: "original.txt", contents: "original", in: root)
        let fileSystem = LocalFlashFileBrowserFileSystem()

        await expectFileSystemError(.invalidName) {
            _ = try await fileSystem.createFolder(
                named: name,
                in: root,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.invalidName) {
            _ = try await fileSystem.rename(
                original,
                expectedIdentity: try itemIdentity(at: original),
                to: name,
                in: root,
                allowedRoot: root
            )
        }

        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test
    func conflictsNeverOverwriteExistingItems() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeFile(named: "source.txt", contents: "source", in: root)
        let destination = try makeFile(
            named: "destination.txt",
            contents: "destination",
            in: root
        )
        let fileSystem = LocalFlashFileBrowserFileSystem()

        await expectFileSystemError(.itemAlreadyExists("destination.txt")) {
            _ = try await fileSystem.createFolder(
                named: "destination.txt",
                in: root,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.itemAlreadyExists("destination.txt")) {
            _ = try await fileSystem.rename(
                source,
                expectedIdentity: try itemIdentity(at: source),
                to: "destination.txt",
                in: root,
                allowedRoot: root
            )
        }

        try #expect(String(contentsOf: source, encoding: .utf8) == "source")
        try #expect(String(contentsOf: destination, encoding: .utf8) == "destination")
    }

    @Test
    func rejectsOutsideAndStaleItems() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let outsideItem = try makeFile(
            named: "outside.txt",
            contents: "outside",
            in: outside
        )
        let nested = try makeDirectory(named: "Nested", in: root)
        let nestedItem = try makeFile(named: "nested.txt", contents: "nested", in: nested)
        let missingItem = root.appendingPathComponent("missing.txt")
        let fileSystem = LocalFlashFileBrowserFileSystem()

        await expectFileSystemError(.outsideWorkingDirectory) {
            _ = try await fileSystem.createFolder(
                named: "Folder",
                in: outside,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.outsideWorkingDirectory) {
            _ = try await fileSystem.rename(
                outsideItem,
                expectedIdentity: try itemIdentity(at: outsideItem),
                to: "renamed.txt",
                in: outside,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.duplicate(
                nestedItem,
                expectedIdentity: try itemIdentity(at: nestedItem),
                in: root,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.itemIsNotCurrent) {
            try await fileSystem.moveToTrash(
                missingItem,
                expectedIdentity: .init(device: 0, inode: 0),
                in: root,
                allowedRoot: root
            )
        }
    }

    @Test
    func pathPolicyDistinguishesLexicalOperationsFromResolvedNavigation() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let root = try makeDirectory(named: "Project", in: container)
        let outside = try makeDirectory(named: "Project-other", in: container)
        let outsideTarget = try makeDirectory(named: "Target", in: outside)
        let link = root.appendingPathComponent("Linked Folder")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outsideTarget
        )

        #expect(FlashFileBrowserPathPolicy.contains(link, in: root))
        #expect(!FlashFileBrowserPathPolicy.containsResolved(link, in: root))
        #expect(!FlashFileBrowserPathPolicy.contains(outside, in: root))
        #expect(FlashFileBrowserPathPolicy.isDirectChild(link, of: root))
    }

    @Test
    func rejectsMutationsInsideSymlinkDirectoryThatEscapesRoot() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let root = try makeDirectory(named: "Project", in: container)
        let outside = try makeDirectory(named: "Outside", in: container)
        let link = root.appendingPathComponent("Linked Folder")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let rootIsAllowed = await fileSystem.isNavigationAllowed(
            root,
            allowedRoot: root
        )
        let escapingLinkIsAllowed = await fileSystem.isNavigationAllowed(
            link,
            allowedRoot: root
        )
        #expect(rootIsAllowed)
        #expect(!escapingLinkIsAllowed)

        await expectFileSystemError(.outsideWorkingDirectory) {
            _ = try await fileSystem.createFolder(
                named: "Must Not Be Created",
                in: link,
                allowedRoot: root
            )
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("Must Not Be Created").path
            )
        )
    }

    @Test
    func navigationRequiresAnExistingDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try makeDirectory(named: "Folder", in: root)
        let file = try makeFile(named: "file.txt", contents: "file", in: root)
        let folderLink = root.appendingPathComponent("Folder Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: folderLink,
            withDestinationURL: folder
        )
        let missing = root.appendingPathComponent("Missing", isDirectory: true)
        let danglingLink = root.appendingPathComponent("Dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: danglingLink,
            withDestinationURL: missing
        )

        let fileSystem = LocalFlashFileBrowserFileSystem()
        let rootIsAllowed = await fileSystem.isNavigationAllowed(
            root,
            allowedRoot: root
        )
        let folderIsAllowed = await fileSystem.isNavigationAllowed(
            folder,
            allowedRoot: root
        )
        let fileIsAllowed = await fileSystem.isNavigationAllowed(
            file,
            allowedRoot: root
        )
        let folderLinkIsAllowed = await fileSystem.isNavigationAllowed(
            folderLink,
            allowedRoot: root
        )
        let missingIsAllowed = await fileSystem.isNavigationAllowed(
            missing,
            allowedRoot: root
        )
        let danglingLinkIsAllowed = await fileSystem.isNavigationAllowed(
            danglingLink,
            allowedRoot: root
        )

        #expect(rootIsAllowed)
        #expect(folderIsAllowed)
        #expect(folderLinkIsAllowed)
        #expect(!fileIsAllowed)
        #expect(!missingIsAllowed)
        #expect(!danglingLinkIsAllowed)
    }

    @Test
    func mutationsRejectItemsReplacedAtTheSamePathAfterListing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let renameURL = try makeFile(
            named: "rename.txt",
            contents: "original rename",
            in: root
        )
        let duplicateURL = try makeFile(
            named: "duplicate.txt",
            contents: "original duplicate",
            in: root
        )
        let trashURL = try makeFile(
            named: "trash.txt",
            contents: "original trash",
            in: root
        )
        let trashRecorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashHandler: { url in
                trashRecorder.append(url)
            }
        )
        let listedItems = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )
        let listedByName = Dictionary(
            uniqueKeysWithValues: listedItems.map { ($0.name, $0) }
        )
        let renameItem = try #require(listedByName[renameURL.lastPathComponent])
        let duplicateItem = try #require(listedByName[duplicateURL.lastPathComponent])
        let trashItem = try #require(listedByName[trashURL.lastPathComponent])

        for (url, replacementContents) in [
            (renameURL, "replacement rename"),
            (duplicateURL, "replacement duplicate"),
            (trashURL, "replacement trash"),
        ] {
            let archivedURL = root.appendingPathComponent("archived-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: archivedURL)
            _ = try makeFile(
                named: url.lastPathComponent,
                contents: replacementContents,
                in: root
            )
        }

        #expect(try itemIdentity(at: renameURL) != renameItem.identity)
        #expect(try itemIdentity(at: duplicateURL) != duplicateItem.identity)
        #expect(try itemIdentity(at: trashURL) != trashItem.identity)

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.rename(
                renameURL,
                expectedIdentity: renameItem.identity,
                to: "renamed.txt",
                in: root,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.duplicate(
                duplicateURL,
                expectedIdentity: duplicateItem.identity,
                in: root,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.itemIsNotCurrent) {
            try await fileSystem.moveToTrash(
                trashURL,
                expectedIdentity: trashItem.identity,
                in: root,
                allowedRoot: root
            )
        }

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("renamed.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("duplicate copy.txt").path
        ))
        #expect(trashRecorder.urls.isEmpty)
        try #expect(String(contentsOf: renameURL, encoding: .utf8) == "replacement rename")
        try #expect(String(contentsOf: duplicateURL, encoding: .utf8) == "replacement duplicate")
        try #expect(String(contentsOf: trashURL, encoding: .utf8) == "replacement trash")
    }

    @Test
    func danglingSymlinkCanBeListedRenamedAndSentToInjectedTrash() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let missingTarget = root.appendingPathComponent("missing-target")
        let renameLink = root.appendingPathComponent("rename-link")
        let trashLink = root.appendingPathComponent("trash-link")
        try FileManager.default.createSymbolicLink(
            at: renameLink,
            withDestinationURL: missingTarget
        )
        try FileManager.default.createSymbolicLink(
            at: trashLink,
            withDestinationURL: missingTarget
        )

        let recorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashHandler: { url in
                recorder.append(url)
            }
        )
        let items = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )
        #expect(items.count == 2)
        #expect(items.map(\.isSymbolicLink) == [true, true])

        let renamed = try await fileSystem.rename(
            renameLink,
            expectedIdentity: try itemIdentity(at: renameLink),
            to: "renamed-link",
            in: root,
            allowedRoot: root
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: renamed.path) ==
                missingTarget.path
        )

        try await fileSystem.moveToTrash(
            trashLink,
            expectedIdentity: try itemIdentity(at: trashLink),
            in: root,
            allowedRoot: root
        )
        #expect(recorder.urls == [trashLink])
    }

    @Test
    func moveToTrashUsesInjectedHandlerWithoutTouchingTheRealTrash() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try makeFile(named: "trash-me.txt", contents: "still here", in: root)
        let recorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashHandler: { url in
                recorder.append(url)
            }
        )

        try await fileSystem.moveToTrash(
            item,
            expectedIdentity: try itemIdentity(at: item),
            in: root,
            allowedRoot: root
        )

        #expect(recorder.urls == [item])
        #expect(FileManager.default.fileExists(atPath: item.path))
        try #expect(String(contentsOf: item, encoding: .utf8) == "still here")
    }

    @Test
    func injectedTrashFailurePropagatesWithoutRemovingTheItem() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try makeFile(named: "keep-me.txt", contents: "keep", in: root)
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashHandler: { _ in
                throw InjectedTrashError.failed
            }
        )

        do {
            try await fileSystem.moveToTrash(
                item,
                expectedIdentity: try itemIdentity(at: item),
                in: root,
                allowedRoot: root
            )
            Issue.record("Expected the injected trash handler to fail")
        } catch let error as InjectedTrashError {
            #expect(error == .failed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: item.path))
    }

    @Test
    func moveToTrashUsesAnchoredSameVolumeDirectory() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(named: "Root", in: container)
        let trash = try makeDirectory(named: "Trash", in: container)
        let item = try makeFile(named: "report.txt", contents: "report", in: root)
        let existing = try makeFile(
            named: "report.txt",
            contents: "existing",
            in: trash
        )
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashDirectoryProvider: { _ in trash }
        )

        try await fileSystem.moveToTrash(
            item,
            expectedIdentity: try itemIdentity(at: item),
            in: root,
            allowedRoot: root
        )

        #expect(!FileManager.default.fileExists(atPath: item.path))
        try #expect(String(contentsOf: existing, encoding: .utf8) == "existing")
        try #expect(
            String(
                contentsOf: trash.appendingPathComponent("report 2.txt"),
                encoding: .utf8
            ) == "report"
        )
    }

    @Test
    func moveToTrashRejectsDestinationReplacedAfterOpen() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(named: "Root", in: container)
        let trash = try makeDirectory(named: "Trash", in: container)
        let replacement = try makeDirectory(named: "Replacement", in: container)
        let archivedTrash = container.appendingPathComponent("Archived Trash")
        let item = try makeFile(named: "keep.txt", contents: "keep", in: root)
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .trashDirectoryOpened = checkpoint else { return }
                try FileManager.default.moveItem(at: trash, to: archivedTrash)
                try FileManager.default.moveItem(at: replacement, to: trash)
            },
            trashDirectoryProvider: { _ in trash }
        )

        await expectFileSystemError(.cannotPrepareTrash) {
            try await fileSystem.moveToTrash(
                item,
                expectedIdentity: try itemIdentity(at: item),
                in: root,
                allowedRoot: root
            )
        }

        try #expect(String(contentsOf: item, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(
            atPath: trash.appendingPathComponent("keep.txt").path
        ))
    }

    @Test
    func copyItemAcceptsOutsideSourcesAndNeverOverwritesConflicts() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        _ = try makeFile(named: "Report.txt", contents: "existing", in: root)
        let source = try makeFile(named: "Report.txt", contents: "incoming", in: outside)
        let fileSystem = LocalFlashFileBrowserFileSystem()

        let firstCopy = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )
        let secondCopy = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )

        #expect(firstCopy.lastPathComponent == "Report copy.txt")
        #expect(secondCopy.lastPathComponent == "Report copy 2.txt")
        try #expect(
            String(
                contentsOf: root.appendingPathComponent("Report.txt"),
                encoding: .utf8
            ) == "existing"
        )
        try #expect(String(contentsOf: firstCopy, encoding: .utf8) == "incoming")
        try #expect(String(contentsOf: secondCopy, encoding: .utf8) == "incoming")
        try #expect(String(contentsOf: source, encoding: .utf8) == "incoming")
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remainingNames.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func copyItemCopiesFoldersAndRejectsCopyingOneIntoItself() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Sources", in: outside)
        _ = try makeFile(named: "child.swift", contents: "let value = 1", in: source)
        let fileSystem = LocalFlashFileBrowserFileSystem()

        let copied = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )
        try #expect(
            String(
                contentsOf: copied.appendingPathComponent("child.swift"),
                encoding: .utf8
            ) == "let value = 1"
        )
        #expect(await fileSystem.isNavigationAllowed(copied, allowedRoot: root))

        await expectFileSystemError(.cannotCopyIntoItself) {
            _ = try await fileSystem.copyItem(
                root,
                to: copied,
                allowedRoot: root
            )
        }
    }

    @Test
    func cancellingRecursiveCopyCleansStagingWithoutPromoting() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Sources", in: outside)
        _ = try makeFile(named: "payload.txt", contents: "payload", in: source)
        let barrier = CopyMutationBarrier()
        defer { barrier.resumeCopy() }
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, copiedSource in
                guard case .copyEntryCopied = checkpoint,
                      copiedSource.lastPathComponent == "payload.txt" else {
                    return
                }
                barrier.pauseCopy()
            }
        )

        let copyTask = Task {
            try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }
        let copyPaused = await Task.detached {
            barrier.waitUntilCopyPauses()
        }.value
        #expect(copyPaused)

        copyTask.cancel()
        barrier.resumeCopy()

        do {
            _ = try await copyTask.value
            Issue.record("Expected the recursive copy to observe cancellation")
        } catch is CancellationError {
            // Expected after the staged entry completes its mutation hook.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let remainingNames = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        )
        #expect(!remainingNames.contains(source.lastPathComponent))
        #expect(!remainingNames.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func descriptorCopyPreservesMetadataAndSymbolicLinks() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Metadata", in: outside)
        let file = try makeFile(named: "payload.txt", contents: "payload", in: source)
        let link = source.appendingPathComponent("payload-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .modificationDate: fixedDate],
            ofItemAtPath: file.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o750, .modificationDate: fixedDate],
            ofItemAtPath: source.path
        )
        try setExtendedAttribute(
            Data("file-xattr".utf8),
            named: "com.flash-ghostty.copy-test",
            at: file
        )
        try setExtendedAttribute(
            Data("directory-xattr".utf8),
            named: "com.flash-ghostty.copy-test",
            at: source
        )
        try setExtendedAttribute(
            Data("link-xattr".utf8),
            named: "com.flash-ghostty.copy-test",
            at: link,
            options: XATTR_NOFOLLOW
        )
        let fileSystem = LocalFlashFileBrowserFileSystem()

        let copied = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )
        let copiedFile = copied.appendingPathComponent("payload.txt")
        let copiedLink = copied.appendingPathComponent("payload-link")

        try #expect(String(contentsOf: copiedFile, encoding: .utf8) == "payload")
        #expect(try posixPermissions(at: copiedFile) == 0o640)
        #expect(try posixPermissions(at: copied) == 0o750)
        #expect(try modificationDate(at: copiedFile) == fixedDate)
        #expect(
            try extendedAttribute(
                named: "com.flash-ghostty.copy-test",
                at: copiedFile
            ) == Data("file-xattr".utf8)
        )
        #expect(
            try extendedAttribute(
                named: "com.flash-ghostty.copy-test",
                at: copied
            ) == Data("directory-xattr".utf8)
        )
        #expect(
            try extendedAttribute(
                named: "com.flash-ghostty.copy-test",
                at: copiedLink,
                options: XATTR_NOFOLLOW
            ) == Data("link-xattr".utf8)
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path) ==
                file.path
        )
    }

    @Test
    func copyUsesAnchoredSourceDuringAncestorSwapReturn() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(named: "Root", in: container)
        let firstParent = try makeDirectory(named: "First", in: container)
        let secondParent = try makeDirectory(named: "Second", in: container)
        _ = try makeFile(named: "source.txt", contents: "intended", in: firstParent)
        _ = try makeFile(named: "source.txt", contents: "outside-secret", in: secondParent)
        let parentLink = container.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: firstParent
        )
        let source = parentLink.appendingPathComponent("source.txt")
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                switch checkpoint {
                case .copySourceOpened:
                    try FileManager.default.removeItem(at: parentLink)
                    try FileManager.default.createSymbolicLink(
                        at: parentLink,
                        withDestinationURL: secondParent
                    )
                case .copySourceFinished:
                    try FileManager.default.removeItem(at: parentLink)
                    try FileManager.default.createSymbolicLink(
                        at: parentLink,
                        withDestinationURL: firstParent
                    )
                default:
                    break
                }
            }
        )

        let copied = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )

        try #expect(String(contentsOf: copied, encoding: .utf8) == "intended")
    }

    @Test
    func copyUsesAnchoredStagingDirectoryDuringSwapReturn() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeFile(named: "source.txt", contents: "source", in: outside)
        let leakRecorder = LockedBoolRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, temporary in
                let archived = temporary.deletingLastPathComponent()
                    .appendingPathComponent(".archived-copy-stage")
                switch checkpoint {
                case .copyDestinationOpened:
                    try FileManager.default.moveItem(at: temporary, to: archived)
                    try FileManager.default.createDirectory(
                        at: temporary,
                        withIntermediateDirectories: false
                    )
                case .copyDestinationFinished:
                    leakRecorder.set(FileManager.default.fileExists(
                        atPath: temporary.appendingPathComponent("source.txt").path
                    ))
                    try FileManager.default.removeItem(at: temporary)
                    try FileManager.default.moveItem(at: archived, to: temporary)
                default:
                    break
                }
            }
        )

        let copied = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )

        try #expect(String(contentsOf: copied, encoding: .utf8) == "source")
        #expect(!leakRecorder.value)
    }

    @Test
    func copyRejectsReplacedStagedRegularFile() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeFile(named: "source.txt", contents: "source", in: outside)
        let didReplace = LockedBoolRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, copiedSource in
                guard case .copyEntryCopied = checkpoint,
                      copiedSource.lastPathComponent == source.lastPathComponent,
                      !didReplace.value else {
                    return
                }
                let stagingName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: root.path)
                        .first { $0.hasPrefix(".flash-ghostty-copy-") }
                )
                let stagedItem = root
                    .appendingPathComponent(stagingName, isDirectory: true)
                    .appendingPathComponent(source.lastPathComponent)
                try FileManager.default.removeItem(at: stagedItem)
                try "replacement".write(
                    to: stagedItem,
                    atomically: false,
                    encoding: .utf8
                )
                didReplace.set(true)
            }
        )

        await expectFileSystemError(.cannotPrepareCopy) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        #expect(didReplace.value)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(source.lastPathComponent).path
        ))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func copyRejectsReplacedStagedDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Sources", in: outside)
        let didReplace = LockedBoolRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, copiedSource in
                guard case .copyEntryCopied = checkpoint,
                      copiedSource.lastPathComponent == source.lastPathComponent,
                      !didReplace.value else {
                    return
                }
                let stagingName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: root.path)
                        .first { $0.hasPrefix(".flash-ghostty-copy-") }
                )
                let stagedItem = root
                    .appendingPathComponent(stagingName, isDirectory: true)
                    .appendingPathComponent(source.lastPathComponent, isDirectory: true)
                try FileManager.default.removeItem(at: stagedItem)
                try FileManager.default.createDirectory(
                    at: stagedItem,
                    withIntermediateDirectories: false
                )
                didReplace.set(true)
            }
        )

        await expectFileSystemError(.cannotPrepareCopy) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        #expect(didReplace.value)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(source.lastPathComponent).path
        ))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func copyRejectsReplacedStagedSymbolicLink() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let target = try makeFile(named: "target.txt", contents: "target", in: outside)
        let replacementTarget = try makeFile(
            named: "replacement.txt",
            contents: "replacement",
            in: outside
        )
        let source = outside.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let didReplace = LockedBoolRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, copiedSource in
                guard case .copyEntryCopied = checkpoint,
                      copiedSource.lastPathComponent == source.lastPathComponent,
                      !didReplace.value else {
                    return
                }
                let stagingName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: root.path)
                        .first { $0.hasPrefix(".flash-ghostty-copy-") }
                )
                let stagedItem = root
                    .appendingPathComponent(stagingName, isDirectory: true)
                    .appendingPathComponent(source.lastPathComponent)
                try FileManager.default.removeItem(at: stagedItem)
                try FileManager.default.createSymbolicLink(
                    at: stagedItem,
                    withDestinationURL: replacementTarget
                )
                didReplace.set(true)
            }
        )

        await expectFileSystemError(.cannotPrepareCopy) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        #expect(didReplace.value)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(source.lastPathComponent).path
        ))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func partialDescriptorCopyFailureCleansAnchoredStaging() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Sources", in: outside)
        _ = try makeFile(named: "first.txt", contents: "first", in: source)
        _ = try makeFile(named: "fail-after.txt", contents: "second", in: source)
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, copiedSource in
                guard case .copyEntryCopied = checkpoint,
                      copiedSource.lastPathComponent == "fail-after.txt" else {
                    return
                }
                throw InjectedCopyError.failed
            }
        )

        do {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
            Issue.record("Expected the injected copy failure")
        } catch let error as InjectedCopyError {
            #expect(error == .failed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains("Sources"))
        #expect(!names.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func copyCleanupTraversesTheTemporaryWrapperAtMaximumDepth() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        // The copied source is depth zero. Its 255th nested directory is the
        // deepest directory the production copy traversal can create.
        let maximumCopyDepth = 256
        let source = try makeDirectory(named: "Sources", in: outside)
        var deepestSource = source
        for _ in 1..<maximumCopyDepth {
            deepestSource = try makeDirectory(named: "d", in: deepestSource)
        }
        let deepestSourceURL = deepestSource

        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, copiedSource in
                guard case .copyEntryCopied = checkpoint else { return }
                guard
                      copiedSource.standardizedFileURL.path ==
                        deepestSourceURL.standardizedFileURL.path else { return }

                let stagingName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: root.path)
                        .first { $0.hasPrefix(".flash-ghostty-copy-") }
                )
                var stagedDeepest = root
                    .appendingPathComponent(stagingName, isDirectory: true)
                    .appendingPathComponent(
                        source.lastPathComponent,
                        isDirectory: true
                    )
                for _ in 1..<maximumCopyDepth {
                    stagedDeepest.appendPathComponent("d", isDirectory: true)
                }

                // Simulate a late same-user mutation inside the app-owned
                // deepest directory, then fail so deferred cleanup must walk
                // through both the copy tree and its temporary wrapper.
                try Data("injected".utf8).write(
                    to: stagedDeepest.appendingPathComponent("injected.txt")
                )
                throw InjectedCopyError.failed
            }
        )

        do {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
            Issue.record("Expected the injected deepest-copy failure")
        } catch let error as InjectedCopyError {
            #expect(error == .failed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let remainingNames = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        )
        #expect(!remainingNames.contains(source.lastPathComponent))
        #expect(!remainingNames.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func lateCopyFailureCleansStagingWithReadOnlyDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Read Only", in: outside)
        _ = try makeFile(named: "payload.txt", contents: "payload", in: source)
        let chmodResult = source.path.withCString {
            Darwin.chmod($0, mode_t(0o555))
        }
        guard chmodResult == 0 else { throw POSIXError(.EIO) }
        defer {
            _ = source.path.withCString {
                Darwin.chmod($0, mode_t(0o700))
            }
        }
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .stagedCopyReady = checkpoint else { return }
                throw InjectedCopyError.failed
            }
        )

        do {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
            Issue.record("Expected the injected copy failure")
        } catch let error as InjectedCopyError {
            #expect(error == .failed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains("Read Only"))
        #expect(!names.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func lateCopyFailureCleansStagingWithImmutableFile() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeFile(
            named: "immutable.txt",
            contents: "immutable",
            in: outside
        )
        let chflagsResult = source.path.withCString {
            Darwin.chflags($0, UInt32(UF_IMMUTABLE))
        }
        guard chflagsResult == 0 else { throw POSIXError(.EIO) }
        defer {
            _ = source.path.withCString { Darwin.chflags($0, 0) }
        }
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .stagedCopyReady = checkpoint else { return }
                throw InjectedCopyError.failed
            }
        )

        do {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
            Issue.record("Expected the injected copy failure")
        } catch let error as InjectedCopyError {
            #expect(error == .failed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains("immutable.txt"))
        #expect(!names.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func descriptorCopyRejectsSpecialFilesAndCleansStaging() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Special", in: outside)
        let fifo = source.appendingPathComponent("unsupported.fifo")
        let createResult = fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        guard createResult == 0 else { throw POSIXError(.EIO) }
        let fileSystem = LocalFlashFileBrowserFileSystem()

        await expectFileSystemError(.cannotPrepareCopy) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix(".flash-ghostty-copy-") })
    }

    @Test
    func batchTrashPreflightsEveryIdentityBeforeMovingAnything() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFile(named: "first.txt", contents: "first", in: root)
        let second = try makeFile(named: "second.txt", contents: "second", in: root)
        let recorder = LockedURLRecorder()
        let fileSystem: any FlashFileBrowserFileSystem =
            LocalFlashFileBrowserFileSystem(
                trashHandler: { recorder.append($0) }
            )
        let targets = [
            FlashFileBrowserMutationTarget(
                url: first,
                expectedIdentity: try itemIdentity(at: first)
            ),
            FlashFileBrowserMutationTarget(
                url: second,
                expectedIdentity: .init(device: 0, inode: 0)
            ),
        ]

        await expectFileSystemError(.itemIsNotCurrent) {
            try await fileSystem.moveToTrash(
                targets,
                in: root,
                allowedRoot: root
            )
        }
        #expect(recorder.urls.isEmpty)
    }

    @Test
    func batchTrashRechecksEachIdentityImmediatelyBeforeMovingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFile(named: "first.txt", contents: "first", in: root)
        let second = try makeFile(named: "second.txt", contents: "second", in: root)
        let firstIdentity = try itemIdentity(at: first)
        let secondIdentity = try itemIdentity(at: second)
        let recorder = LockedURLRecorder()
        let fileManager = FileManager.default
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashHandler: { url in
                recorder.append(url)
                if url.standardizedFileURL == first.standardizedFileURL {
                    try FileManager.default.removeItem(at: first)
                    try FileManager.default.removeItem(at: second)
                    try "replacement".write(
                        to: second,
                        atomically: true,
                        encoding: .utf8
                    )
                }
            }
        )
        let targets = [
            FlashFileBrowserMutationTarget(
                url: first,
                expectedIdentity: firstIdentity
            ),
            FlashFileBrowserMutationTarget(
                url: second,
                expectedIdentity: secondIdentity
            ),
        ]

        await expectFileSystemError(
            .batchOperationFailed(
                completed: 1,
                total: 2,
                reason: FlashFileBrowserFileSystemError.itemIsNotCurrent.localizedDescription
            )
        ) {
            try await fileSystem.moveToTrash(
                targets,
                in: root,
                allowedRoot: root
            )
        }

        #expect(recorder.urls == [first])
        #expect(!fileManager.fileExists(atPath: first.path))
        try #expect(String(contentsOf: second, encoding: .utf8) == "replacement")
        #expect(try itemIdentity(at: second) != secondIdentity)
    }

    @Test
    func rejectsRootRenamedAndReplacedAtTheSamePath() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(named: "Project", in: container)
        _ = try makeFile(named: "original.txt", contents: "original", in: root)
        let fileSystem = LocalFlashFileBrowserFileSystem()

        try await fileSystem.bindRoot(root)
        _ = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )

        let archived = container.appendingPathComponent("Project archived")
        try FileManager.default.moveItem(at: root, to: archived)
        let replacement = try makeDirectory(named: "Project", in: container)
        let replacementFile = try makeFile(
            named: "must-stay.txt",
            contents: "replacement",
            in: replacement
        )

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.contents(
                of: root,
                showingHiddenFiles: false,
                allowedRoot: root
            )
        }
        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.createFolder(
                named: "Must Not Be Created",
                in: root,
                allowedRoot: root
            )
        }

        try #expect(String(contentsOf: replacementFile, encoding: .utf8) == "replacement")
        #expect(!FileManager.default.fileExists(
            atPath: replacement.appendingPathComponent("Must Not Be Created").path
        ))
    }

    @Test
    func rejectsRootSymlinkRetargetedAfterBinding() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try makeDirectory(named: "First", in: container)
        let second = try makeDirectory(named: "Second", in: container)
        let rootLink = container.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: first)
        let fileSystem = LocalFlashFileBrowserFileSystem()

        try await fileSystem.bindRoot(rootLink)
        try FileManager.default.removeItem(at: rootLink)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: second)

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.createFolder(
                named: "Must Not Be Created",
                in: rootLink,
                allowedRoot: rootLink
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: second.appendingPathComponent("Must Not Be Created").path
        ))
    }

    @Test
    func rejectsAncestorSymlinkRetargetedAfterBinding() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let firstParent = try makeDirectory(named: "First", in: container)
        let secondParent = try makeDirectory(named: "Second", in: container)
        _ = try makeDirectory(named: "Project", in: firstParent)
        let replacementRoot = try makeDirectory(named: "Project", in: secondParent)
        let parentLink = container.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: firstParent
        )
        let lexicalRoot = parentLink.appendingPathComponent("Project")
        let fileSystem = LocalFlashFileBrowserFileSystem()

        try await fileSystem.bindRoot(lexicalRoot)
        try FileManager.default.removeItem(at: parentLink)
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: secondParent
        )

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.createFolder(
                named: "Must Not Be Created",
                in: lexicalRoot,
                allowedRoot: lexicalRoot
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: replacementRoot.appendingPathComponent("Must Not Be Created").path
        ))
    }

    @Test
    func rejectsAncestorRetargetBetweenResolutionAndDirectoryOpen() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(named: "Root", in: container)
        let insideParent = try makeDirectory(named: "Inside", in: root)
        let outsideParent = try makeDirectory(named: "Outside", in: container)
        let project = try makeDirectory(named: "Project", in: insideParent)
        let outsideProject = outsideParent.appendingPathComponent("Project")
        let parentLink = root.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: insideParent
        )
        let lexicalDirectory = parentLink.appendingPathComponent("Project")
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, directory in
                guard case .directoryEntryRead = checkpoint,
                      directory.path == lexicalDirectory.standardizedFileURL.path,
                      FileManager.default.fileExists(atPath: project.path) else {
                    return
                }
                try FileManager.default.moveItem(at: project, to: outsideProject)
                try FileManager.default.removeItem(at: parentLink)
                try FileManager.default.createSymbolicLink(
                    at: parentLink,
                    withDestinationURL: outsideParent
                )
            }
        )

        try await fileSystem.bindRoot(root)

        #expect(!(await fileSystem.isNavigationAllowed(
            lexicalDirectory,
            allowedRoot: root
        )))
        #expect(FileManager.default.fileExists(atPath: outsideProject.path))
    }

    @Test
    func rejectsCurrentDirectoryReplacedAfterNavigationValidation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try makeDirectory(named: "Child", in: root)
        let fileSystem = LocalFlashFileBrowserFileSystem()
        try await fileSystem.bindRoot(root)
        #expect(await fileSystem.isNavigationAllowed(child, allowedRoot: root))

        let archived = root.appendingPathComponent("Child archived")
        try FileManager.default.moveItem(at: child, to: archived)
        let replacement = try makeDirectory(named: "Child", in: root)

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.createFolder(
                named: "Must Not Be Created",
                in: replacement,
                allowedRoot: root
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: replacement.appendingPathComponent("Must Not Be Created").path
        ))
    }

    @Test
    func explicitNavigationRebindsARecreatedChildDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try makeDirectory(named: "Child", in: root)
        let fileSystem = LocalFlashFileBrowserFileSystem()
        try await fileSystem.bindRoot(root)
        #expect(await fileSystem.isNavigationAllowed(child, allowedRoot: root))

        let archived = root.appendingPathComponent("Child archived")
        try FileManager.default.moveItem(at: child, to: archived)
        let replacement = try makeDirectory(named: "Child", in: root)

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.contents(
                of: replacement,
                showingHiddenFiles: false,
                allowedRoot: root
            )
        }

        #expect(await fileSystem.isNavigationAllowed(root, allowedRoot: root))
        #expect(await fileSystem.isNavigationAllowed(replacement, allowedRoot: root))
        let created = try await fileSystem.createFolder(
            named: "Created after re-entry",
            in: replacement,
            allowedRoot: root
        )
        #expect(FileManager.default.fileExists(atPath: created.path))
    }

    @Test
    func createFailsClosedWhenAncestorRetargetsAfterDirectoryOpen() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let firstParent = try makeDirectory(named: "First", in: container)
        let secondParent = try makeDirectory(named: "Second", in: container)
        let firstRoot = try makeDirectory(named: "Project", in: firstParent)
        let secondRoot = try makeDirectory(named: "Project", in: secondParent)
        let parentLink = container.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: firstParent
        )
        let lexicalRoot = parentLink.appendingPathComponent("Project")
        let fileSystem = LocalFlashFileBrowserFileSystem(mutationHook: { checkpoint, _ in
            guard case .directoryOpened = checkpoint else { return }
            try FileManager.default.removeItem(at: parentLink)
            try FileManager.default.createSymbolicLink(
                at: parentLink,
                withDestinationURL: secondParent
            )
        })
        try await fileSystem.bindRoot(lexicalRoot)

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.createFolder(
                named: "Must Not Be Created",
                in: lexicalRoot,
                allowedRoot: lexicalRoot
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: firstRoot.appendingPathComponent("Must Not Be Created").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: secondRoot.appendingPathComponent("Must Not Be Created").path
        ))
    }

    @Test
    func createFailsClosedWhenOpenDirectoryMovesOutsideRoot() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(named: "Root", in: container)
        let insideParent = try makeDirectory(named: "Inside", in: root)
        let outsideParent = try makeDirectory(named: "Outside", in: container)
        let project = try makeDirectory(named: "Project", in: insideParent)
        let outsideProject = outsideParent.appendingPathComponent("Project")
        let parentLink = root.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: insideParent
        )
        let lexicalDirectory = parentLink.appendingPathComponent("Project")
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .directoryOpened = checkpoint,
                      FileManager.default.fileExists(atPath: project.path) else {
                    return
                }
                try FileManager.default.moveItem(at: project, to: outsideProject)
                try FileManager.default.removeItem(at: parentLink)
                try FileManager.default.createSymbolicLink(
                    at: parentLink,
                    withDestinationURL: outsideParent
                )
            }
        )

        try await fileSystem.bindRoot(root)
        #expect(await fileSystem.isNavigationAllowed(
            lexicalDirectory,
            allowedRoot: root
        ))

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.createFolder(
                named: "Must Not Be Created",
                in: lexicalDirectory,
                allowedRoot: root
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: outsideProject.appendingPathComponent("Must Not Be Created").path
        ))
    }

    @Test
    func copyDoesNotPromoteWhenAncestorRetargetsAfterStaging() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let firstParent = try makeDirectory(named: "First", in: container)
        let secondParent = try makeDirectory(named: "Second", in: container)
        let firstRoot = try makeDirectory(named: "Project", in: firstParent)
        let secondRoot = try makeDirectory(named: "Project", in: secondParent)
        let source = try makeFile(named: "source.txt", contents: "source", in: container)
        let parentLink = container.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: firstParent
        )
        let lexicalRoot = parentLink.appendingPathComponent("Project")
        let fileSystem = LocalFlashFileBrowserFileSystem(mutationHook: { checkpoint, _ in
            guard case .stagedCopyReady = checkpoint else { return }
            try FileManager.default.removeItem(at: parentLink)
            try FileManager.default.createSymbolicLink(
                at: parentLink,
                withDestinationURL: secondParent
            )
        })
        try await fileSystem.bindRoot(lexicalRoot)

        await expectFileSystemError(.workingDirectoryChanged) {
            _ = try await fileSystem.copyItem(
                source,
                to: lexicalRoot,
                allowedRoot: lexicalRoot
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: firstRoot.appendingPathComponent("source.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: secondRoot.appendingPathComponent("source.txt").path
        ))
        let firstNames = try FileManager.default.contentsOfDirectory(atPath: firstRoot.path)
        #expect(!firstNames.contains { $0.hasPrefix(".flash-ghostty-") })
    }
}

private extension FlashFileBrowserFileSystemTests {
    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashFileBrowserFileSystemTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory.standardizedFileURL
    }

    @discardableResult
    func makeDirectory(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url.standardizedFileURL
    }

    @discardableResult
    func makeFile(named name: String, contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    func makeApplicationPackage(named name: String, in directory: URL) throws -> URL {
        let package = try makeDirectory(named: name, in: directory)
        let contents = try makeDirectory(named: "Contents", in: package)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        return package
    }

    func setExtendedAttribute(
        _ value: Data,
        named name: String,
        at url: URL,
        options: Int32 = 0
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            url.path.withCString { path in
                name.withCString { attributeName in
                    Darwin.setxattr(
                        path,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        options
                    )
                }
            }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
    }

    func extendedAttribute(
        named name: String,
        at url: URL,
        options: Int32 = 0
    ) throws -> Data {
        let size = url.path.withCString { path in
            name.withCString { attributeName in
                Darwin.getxattr(path, attributeName, nil, 0, 0, options)
            }
        }
        guard size >= 0 else { throw POSIXError(.EIO) }
        var value = Data(count: size)
        let result = value.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                name.withCString { attributeName in
                    Darwin.getxattr(
                        path,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        options
                    )
                }
            }
        }
        guard result == size else { throw POSIXError(.EIO) }
        return value
    }

    func posixPermissions(at url: URL) throws -> mode_t {
        var metadata = stat()
        let path = FileManager.default.fileSystemRepresentation(withPath: url.path)
        let result = Darwin.lstat(path, &metadata)
        guard result == 0 else { throw POSIXError(.EIO) }
        return metadata.st_mode & mode_t(0o777)
    }

    func modificationDate(at url: URL) throws -> Date {
        var metadata = stat()
        let path = FileManager.default.fileSystemRepresentation(withPath: url.path)
        let result = Darwin.lstat(path, &metadata)
        guard result == 0 else { throw POSIXError(.EIO) }
        return Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec) +
                TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    func itemIdentity(at url: URL) throws -> FlashFileBrowserItemIdentity {
        var metadata = stat()
        let path = FileManager.default.fileSystemRepresentation(withPath: url.path)
        guard Darwin.lstat(path, &metadata) == 0 else {
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }

        return FlashFileBrowserItemIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            generation: metadata.st_gen,
            birthtimeSeconds: Int64(metadata.st_birthtimespec.tv_sec),
            birthtimeNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec)
        )
    }

    func expectFileSystemError(
        _ expected: FlashFileBrowserFileSystemError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected filesystem error: \(expected)")
        } catch let error as FlashFileBrowserFileSystemError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private enum InjectedTrashError: Error, Equatable {
    case failed
}

private enum InjectedCopyError: Error, Equatable {
    case failed
}

private final class LockedURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}

private final class LockedBoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class CopyMutationBarrier: @unchecked Sendable {
    private let copyPaused = DispatchSemaphore(value: 0)
    private let copyMayResume = DispatchSemaphore(value: 0)

    func pauseCopy() {
        copyPaused.signal()
        _ = copyMayResume.wait(timeout: .now() + 30)
    }

    func waitUntilCopyPauses() -> Bool {
        copyPaused.wait(timeout: .now() + 5) == .success
    }

    func resumeCopy() {
        copyMayResume.signal()
    }
}
