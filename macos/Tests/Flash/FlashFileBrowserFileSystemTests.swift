import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserFileSystemTests {
    @Test
    func repeatedDescriptorEnumerationStartsAtTheBeginning() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeFile(named: "first.txt", contents: "first", in: root)
        let path = FileManager.default.fileSystemRepresentation(withPath: root.path)
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FlashFileBrowserDescriptorIO.currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }

        var firstScan: [String] = []
        try FlashFileBrowserDescriptorIO.forEachDirectoryEntry(in: descriptor) {
            firstScan.append($0)
        }
        var secondScan: [String] = []
        try FlashFileBrowserDescriptorIO.forEachDirectoryEntry(in: descriptor) {
            secondScan.append($0)
        }
        _ = try makeFile(named: "second.txt", contents: "second", in: root)
        var thirdScan: [String] = []
        try FlashFileBrowserDescriptorIO.forEachDirectoryEntry(in: descriptor) {
            thirdScan.append($0)
        }

        #expect(Set(firstScan) == ["first.txt"])
        #expect(Set(secondScan) == ["first.txt"])
        #expect(Set(thirdScan) == ["first.txt", "second.txt"])
    }

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
    func contentsEnumeratesTenThousandRealFilesystemEntriesWithinBudget() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryCount = 10_000
        let fileManager = FileManager.default

        // Fixture setup is intentionally outside the measurement. Creating
        // 10k files exercises the test host and filesystem rather than the
        // File Browser read path, and would make the budget depend on runner
        // provisioning instead of the production operation under test.
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

        let fileSystem = LocalFlashFileBrowserFileSystem()
        // This is a regression ceiling for the deterministic newly-created
        // fixture, not a cold-storage benchmark: CI cannot safely flush global
        // APFS caches. Healthy reads are subsecond, including under local
        // four-way load. Three seconds leaves virtualized CI and filesystem
        // scanners ample headroom while still rejecting a user-visible stall.
        let wallClockBudget: Duration = .seconds(3)
        let clock = ContinuousClock()

        // Measure the first production read end to end: actor scheduling,
        // root/descriptor validation, descriptor-relative enumeration and
        // metadata reads, item identity construction, and final revalidation.
        // Correctness assertions and collection materialization below are not
        // charged to the filesystem budget.
        let measurementStart = clock.now
        let items = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )
        let elapsed = measurementStart.duration(to: clock.now)
        let names = Set(items.map(\.name))

        #expect(
            elapsed < wallClockBudget,
            "Reading 10k real entries took \(elapsed); budget is \(wallClockBudget)"
        )
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
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) ==
                ["New Folder"]
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: created.path).isEmpty)
    }

    @Test
    func createPreservesAnEntryThatAlreadyOwnsTheFinalName() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let requestedName = "New Folder"
        let markerName = "installed-by-another-process.txt"
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, destination in
                guard case .folderCreationReady = checkpoint else { return }
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                try Data("preserve".utf8).write(
                    to: destination.appendingPathComponent(markerName)
                )
            }
        )

        await expectFileSystemError(.itemAlreadyExists(requestedName)) {
            _ = try await fileSystem.createFolder(
                named: requestedName,
                in: root,
                allowedRoot: root
            )
        }

        try #expect(String(
            contentsOf: root
                .appendingPathComponent(requestedName)
                .appendingPathComponent(markerName),
            encoding: .utf8
        ) == "preserve")
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) ==
                [requestedName]
        )
    }

    @Test
    func createRejectsAStagingReplacementBeforeDescriptorPinning() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archivedStaging = root.appendingPathComponent(
            "Archived staged folder",
            isDirectory: true
        )
        let recorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, stagedFolder in
                guard case .folderStagingIdentityCaptured = checkpoint else { return }
                recorder.append(stagedFolder)
                try FileManager.default.moveItem(
                    at: stagedFolder,
                    to: archivedStaging
                )
                try FileManager.default.createDirectory(
                    at: stagedFolder,
                    withIntermediateDirectories: false
                )
            }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.createFolder(
                named: "New Folder",
                in: root,
                allowedRoot: root
            )
        }

        let stagedFolder = try #require(recorder.urls.first)
        #expect(FileManager.default.fileExists(atPath: archivedStaging.path))
        #expect(FileManager.default.fileExists(atPath: stagedFolder.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("New Folder").path
        ))
    }

    @Test
    func createRejectsAStagingReplacementAfterDescriptorPinning() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archivedStaging = root.appendingPathComponent(
            "Pinned staged folder",
            isDirectory: true
        )
        let recorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, stagedFolder in
                guard case .folderStaged = checkpoint else { return }
                recorder.append(stagedFolder)
                try FileManager.default.moveItem(
                    at: stagedFolder,
                    to: archivedStaging
                )
                try FileManager.default.createDirectory(
                    at: stagedFolder,
                    withIntermediateDirectories: false
                )
            }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.createFolder(
                named: "New Folder",
                in: root,
                allowedRoot: root
            )
        }

        let stagedFolder = try #require(recorder.urls.first)
        #expect(FileManager.default.fileExists(atPath: archivedStaging.path))
        #expect(FileManager.default.fileExists(atPath: stagedFolder.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("New Folder").path
        ))
    }

    @Test
    func createRejectsASourceSwapImmediatelyBeforePromotion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let requestedName = "New Folder"
        let markerName = "replacement-marker.txt"
        let archivedStaging = root.appendingPathComponent(
            "Original staged folder",
            isDirectory: true
        )
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, stagedFolder in
                guard case .folderPromotionReady = checkpoint else { return }
                try FileManager.default.moveItem(
                    at: stagedFolder,
                    to: archivedStaging
                )
                try FileManager.default.createDirectory(
                    at: stagedFolder,
                    withIntermediateDirectories: false
                )
                try Data("preserve".utf8).write(
                    to: stagedFolder.appendingPathComponent(markerName)
                )
            }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.createFolder(
                named: requestedName,
                in: root,
                allowedRoot: root
            )
        }

        let replacement = root.appendingPathComponent(
            requestedName,
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: archivedStaging.path))
        try #expect(String(
            contentsOf: replacement.appendingPathComponent(markerName),
            encoding: .utf8
        ) == "preserve")
    }

    @Test
    func createExclusivePromotionPreservesFinalNameInstalledAfterStaging() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let requestedName = "New Folder"
        let markerName = "unknown-marker.txt"
        let stagingRecorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, stagedFolder in
                guard case .folderPromotionReady = checkpoint else { return }
                stagingRecorder.append(stagedFolder)
                let destination = root.appendingPathComponent(
                    requestedName,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                try Data("preserve".utf8).write(
                    to: destination.appendingPathComponent(markerName)
                )
            }
        )

        await expectFileSystemError(.itemAlreadyExists(requestedName)) {
            _ = try await fileSystem.createFolder(
                named: requestedName,
                in: root,
                allowedRoot: root
            )
        }

        let stagedFolder = try #require(stagingRecorder.urls.first)
        #expect(FileManager.default.fileExists(atPath: stagedFolder.path))
        try #expect(
            String(
                contentsOf: root
                    .appendingPathComponent(requestedName)
                    .appendingPathComponent(markerName),
                encoding: .utf8
            ) == "preserve"
        )
    }

    @Test
    func createRejectsContentInjectedAfterPromotionWithoutDeletingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let requestedName = "New Folder"
        let markerName = "concurrent-marker.txt"
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, created in
                guard case .folderPromoted = checkpoint else { return }
                try Data("preserve".utf8).write(
                    to: created.appendingPathComponent(markerName)
                )
            }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.createFolder(
                named: requestedName,
                in: root,
                allowedRoot: root
            )
        }

        let preservedFolder = root.appendingPathComponent(
            requestedName,
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: preservedFolder.path))
        try #expect(String(
            contentsOf: preservedFolder.appendingPathComponent(markerName),
            encoding: .utf8
        ) == "preserve")
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) ==
                [requestedName]
        )
    }

    @Test
    func createRejectsAReplacementInstalledAfterCommitWithoutDeletingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archivedCreatedName = "Created by FLASH"
        let requestedName = "New Folder"
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, created in
                guard case .folderPromoted = checkpoint else { return }

                let archivedCreated = root.appendingPathComponent(
                    archivedCreatedName,
                    isDirectory: true
                )
                try FileManager.default.moveItem(
                    at: created,
                    to: archivedCreated
                )
                try FileManager.default.createDirectory(
                    at: created,
                    withIntermediateDirectories: false
                )
            }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.createFolder(
                named: requestedName,
                in: root,
                allowedRoot: root
            )
        }

        // The exclusive rename committed before the concurrent replacement.
        // The pinned descriptor detects that its object left the requested
        // name. No pathname rollback runs, so the unknown entry stays put.
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(
            atPath: root
                .appendingPathComponent(archivedCreatedName)
                .path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
        isDirectory = false
        #expect(FileManager.default.fileExists(
            atPath: root
                .appendingPathComponent(requestedName)
                .path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
        let rootEntries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!rootEntries.contains {
            $0.hasPrefix(".flash-ghostty-folder-")
        })
    }

    @Test
    func createRejectsASymlinkInstalledAfterCommitWithoutFollowingIt() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let requestedName = "New Folder"
        let archivedCreated = root.appendingPathComponent(
            "Created by FLASH",
            isDirectory: true
        )
        let sentinel = try makeFile(
            named: "must-stay.txt",
            contents: "outside",
            in: outside
        )
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, created in
                guard case .folderPromoted = checkpoint else { return }
                try FileManager.default.moveItem(
                    at: created,
                    to: archivedCreated
                )
                try FileManager.default.createSymbolicLink(
                    at: created,
                    withDestinationURL: outside
                )
            }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.createFolder(
                named: requestedName,
                in: root,
                allowedRoot: root
            )
        }

        #expect(FileManager.default.fileExists(atPath: archivedCreated.path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: root.appendingPathComponent(requestedName).path
            ) == outside.path
        )
        try #expect(String(contentsOf: sentinel, encoding: .utf8) == "outside")
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: outside.path)) ==
                [sentinel.lastPathComponent]
        )
        let rootEntries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!rootEntries.contains {
            $0.hasPrefix(".flash-ghostty-folder-")
        })
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
    func renameRejectsSourceReplacedAfterValidationWithoutMovingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeFile(
            named: "before.txt",
            contents: "original",
            in: root
        )
        let originalIdentity = try itemIdentity(at: original)
        let archived = root.appendingPathComponent("archived-before.txt")
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .itemValidated = checkpoint else { return }
                try FileManager.default.moveItem(at: original, to: archived)
                _ = try makeFile(
                    named: original.lastPathComponent,
                    contents: "replacement",
                    in: root
                )
            }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            _ = try await fileSystem.rename(
                original,
                expectedIdentity: originalIdentity,
                to: "after.txt",
                in: root,
                allowedRoot: root
            )
        }

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("after.txt").path
        ))
        try #expect(String(contentsOf: archived, encoding: .utf8) == "original")
        try #expect(String(contentsOf: original, encoding: .utf8) == "replacement")
    }

    @Test
    func renameExclusiveCommitPreservesDestinationInstalledAfterValidation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeFile(
            named: "before.txt",
            contents: "original",
            in: root
        )
        let destination = root.appendingPathComponent("after.txt")
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .itemValidated = checkpoint else { return }
                _ = try makeFile(
                    named: destination.lastPathComponent,
                    contents: "unknown destination",
                    in: root
                )
            }
        )

        await expectFileSystemError(.itemAlreadyExists(destination.lastPathComponent)) {
            _ = try await fileSystem.rename(
                original,
                expectedIdentity: try itemIdentity(at: original),
                to: destination.lastPathComponent,
                in: root,
                allowedRoot: root
            )
        }

        try #expect(String(contentsOf: original, encoding: .utf8) == "original")
        try #expect(
            String(contentsOf: destination, encoding: .utf8) == "unknown destination"
        )
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
    func moveToTrashRejectsSourceReplacedAfterValidation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeFile(
            named: "trash-me.txt",
            contents: "original",
            in: root
        )
        let originalIdentity = try itemIdentity(at: original)
        let archived = root.appendingPathComponent("archived-trash-me.txt")
        let recorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .itemValidated = checkpoint else { return }
                try FileManager.default.moveItem(at: original, to: archived)
                _ = try makeFile(
                    named: original.lastPathComponent,
                    contents: "replacement",
                    in: root
                )
            },
            trashHandler: { recorder.append($0) }
        )

        await expectFileSystemError(.itemIsNotCurrent) {
            try await fileSystem.moveToTrash(
                original,
                expectedIdentity: originalIdentity,
                in: root,
                allowedRoot: root
            )
        }

        #expect(recorder.urls.isEmpty)
        try #expect(String(contentsOf: archived, encoding: .utf8) == "original")
        try #expect(String(contentsOf: original, encoding: .utf8) == "replacement")
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
        #expect(!remainingNames.contains { $0.hasPrefix("FLASH Incomplete Copy ") })
    }

    @Test
    func copyPostCommitFailurePreservesFinalReplacementWithoutPathCleanup() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        let source = try makeFile(
            named: "source.txt",
            contents: "intended",
            in: outside
        )
        let archived = root.appendingPathComponent("committed-source.txt")
        let destination = root.appendingPathComponent(source.lastPathComponent)
        defer {
            try? setFileFlags(0, at: source)
            clearFileFlagsOfImmediateChildren(in: root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let protectedFlags = UInt32(UF_HIDDEN) | UInt32(UF_IMMUTABLE)
        try setFileFlags(protectedFlags, at: source)
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, promoted in
                guard case .copyPromoted = checkpoint else { return }
                try FileManager.default.moveItem(at: promoted, to: archived)
                try Data("unknown final".utf8).write(to: promoted)
            }
        )

        await expectFileSystemError(.cannotPrepareCopy) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        try #expect(String(contentsOf: archived, encoding: .utf8) == "intended")
        try #expect(
            String(
                contentsOf: destination,
                encoding: .utf8
            ) == "unknown final"
        )
        #expect((try fileFlags(at: archived) & protectedFlags) == 0)
        #expect((try fileFlags(at: destination) & protectedFlags) == 0)
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remainingNames.contains { $0.hasPrefix("FLASH Incomplete Copy ") })
    }

    @Test
    func copyFinalNameRacePreservesDestinationAndVisibleStaging() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeFile(
            named: "source.txt",
            contents: "intended",
            in: outside
        )
        let destination = root.appendingPathComponent(source.lastPathComponent)
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .stagedCopyReady = checkpoint else { return }
                try Data("unknown final".utf8).write(to: destination)
            }
        )

        await expectFileSystemError(.itemAlreadyExists(source.lastPathComponent)) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        try #expect(String(contentsOf: destination, encoding: .utf8) == "unknown final")
        let staged = try onlyIncompleteCopy(in: root)
        try #expect(String(contentsOf: staged, encoding: .utf8) == "intended")
        #expect(staged.lastPathComponent.hasSuffix(" - source.txt"))
        let stagedItem = try #require(
            try await fileSystem.contents(
                of: root,
                showingHiddenFiles: false,
                allowedRoot: root
            ).first { $0.name == staged.lastPathComponent }
        )
        let textType = FlashFileBrowserFileType(fileExtension: "txt")
        #expect(FlashFileBrowserTypeFilter.fileType(for: stagedItem) == textType)
        #expect(FlashFileBrowserTypeFilter.visibleItems(
            in: [stagedItem],
            query: "source.txt",
            selectedTypes: [textType]
        ) == [stagedItem])
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
    func cancellingRecursiveCopyPreservesStagingWithoutPromoting() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeDirectory(named: "Sources", in: outside)
        _ = try makeFile(named: "payload.txt", contents: "payload", in: source)
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, copiedSource in
                guard case .copyEntryCopied = checkpoint,
                      copiedSource.lastPathComponent == "payload.txt" else {
                    return
                }
                // Cancel the child operation at the exact post-copy
                // checkpoint without blocking a Swift concurrency worker.
                // Semaphore barriers here can exhaust the cooperative thread
                // pool when Swift Testing runs cancellation tests in parallel.
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )

        let copyTask = Task {
            try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

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
        let staging = try onlyIncompleteCopy(in: root)
        let stagedPayload = staging
            .appendingPathComponent("payload.txt")
        try #expect(String(contentsOf: stagedPayload, encoding: .utf8) == "payload")
        let visibleItems = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )
        #expect(visibleItems.contains { $0.name == staging.lastPathComponent })
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
    func copyDefersHiddenDirectoryMetadataUntilAfterPromotion() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        let source = try makeDirectory(named: "Hidden", in: outside)
        _ = try makeFile(named: "payload.txt", contents: "payload", in: source)
        let expectedDestination = root.appendingPathComponent(source.lastPathComponent)
        defer {
            try? setFileFlags(0, at: source)
            try? setFileFlags(0, at: expectedDestination)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try setFileFlags(UInt32(UF_HIDDEN), at: source)
        let stagedWasHidden = LockedBoolRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .stagedCopyReady = checkpoint else { return }
                let staged = try onlyIncompleteCopy(in: root)
                let flags = try fileFlags(at: staged)
                stagedWasHidden.set(flags & UInt32(UF_HIDDEN) != 0)
            }
        )

        let copied = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )

        #expect(!stagedWasHidden.value)
        #expect((try fileFlags(at: copied) & UInt32(UF_HIDDEN)) != 0)
        try #expect(
            String(
                contentsOf: copied.appendingPathComponent("payload.txt"),
                encoding: .utf8
            ) == "payload"
        )
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remainingNames.contains { $0.hasPrefix("FLASH Incomplete Copy ") })
    }

    @Test
    func copyDefersImmutableFileMetadataUntilAfterPromotion() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        let source = try makeFile(
            named: "immutable.txt",
            contents: "immutable",
            in: outside
        )
        let expectedDestination = root.appendingPathComponent(source.lastPathComponent)
        defer {
            try? setFileFlags(0, at: source)
            clearFileFlagsOfImmediateChildren(in: root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try setFileFlags(UInt32(UF_IMMUTABLE), at: source)
        let stagedWasImmutable = LockedBoolRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .stagedCopyReady = checkpoint else { return }
                let staged = try onlyIncompleteCopy(in: root)
                let flags = try fileFlags(at: staged)
                stagedWasImmutable.set(flags & UInt32(UF_IMMUTABLE) != 0)
            }
        )

        let copied = try await fileSystem.copyItem(
            source,
            to: root,
            allowedRoot: root
        )

        #expect(copied == expectedDestination.standardizedFileURL)
        #expect(!stagedWasImmutable.value)
        #expect((try fileFlags(at: copied) & UInt32(UF_IMMUTABLE)) != 0)
        try #expect(String(contentsOf: copied, encoding: .utf8) == "immutable")
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
    func copyDoesNotOverwriteStagingNameClaimedBeforeCopy() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try makeFile(named: "source.txt", contents: "source", in: outside)
        let stagedURLRecorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, stagedURL in
                guard case .copyDestinationOpened = checkpoint else { return }
                stagedURLRecorder.append(stagedURL)
                try Data("unknown staging entry".utf8).write(to: stagedURL)
            }
        )

        await expectFileSystemError(.cannotPrepareCopy) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        let stagedURL = try #require(stagedURLRecorder.urls.first)
        #expect(stagedURL.lastPathComponent.hasPrefix("FLASH Incomplete Copy "))
        #expect(stagedURL.lastPathComponent.hasSuffix(" - source.txt"))
        try #expect(
            String(contentsOf: stagedURL, encoding: .utf8) == "unknown staging entry"
        )
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(source.lastPathComponent).path
        ))
    }

    @Test
    func incompleteCopyNameRespectsNameMaxAtUnicodeBoundaries() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let sourceName = String(repeating: "界", count: 60) +
            String(repeating: "🙂", count: 10) + ".txt"
        let source = try makeFile(named: sourceName, contents: "source", in: outside)
        let stagedURLRecorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, stagedURL in
                guard case .copyDestinationOpened = checkpoint else { return }
                stagedURLRecorder.append(stagedURL)
                try Data("preserve".utf8).write(to: stagedURL)
            }
        )

        await expectFileSystemError(.cannotPrepareCopy) {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
        }

        let stagedURL = try #require(stagedURLRecorder.urls.first)
        let nameMaximum = root.path.withCString {
            Darwin.pathconf($0, _PC_NAME_MAX)
        }
        #expect(nameMaximum > 0)
        #expect(stagedURL.lastPathComponent.utf8.count <= nameMaximum)
        #expect(stagedURL.lastPathComponent.hasPrefix("FLASH Incomplete Copy "))
        #expect(stagedURL.lastPathComponent.hasSuffix(".txt"))
        #expect(!stagedURL.lastPathComponent.hasSuffix(" - \(sourceName)"))
        try #expect(String(contentsOf: stagedURL, encoding: .utf8) == "preserve")
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
                let stagedItem = try onlyIncompleteCopy(in: root)
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
        let stagedReplacement = try onlyIncompleteCopy(in: root)
        try #expect(
            String(contentsOf: stagedReplacement, encoding: .utf8) == "replacement"
        )
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
                let stagedItem = try onlyIncompleteCopy(in: root)
                try FileManager.default.removeItem(at: stagedItem)
                try FileManager.default.createDirectory(
                    at: stagedItem,
                    withIntermediateDirectories: false
                )
                try Data("unknown replacement".utf8).write(
                    to: stagedItem.appendingPathComponent("unknown.txt")
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
        let stagedReplacement = try onlyIncompleteCopy(in: root)
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(
            atPath: stagedReplacement.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
        try #expect(
            String(
                contentsOf: stagedReplacement.appendingPathComponent("unknown.txt"),
                encoding: .utf8
            ) == "unknown replacement"
        )
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
                let stagedItem = try onlyIncompleteCopy(in: root)
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
        let stagedReplacement = try onlyIncompleteCopy(in: root)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: stagedReplacement.path
            ) == replacementTarget.path
        )
    }

    @Test
    func partialDescriptorCopyFailurePreservesVisibleSiblingStaging() async throws {
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

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Sources").path
        ))
        let stagedFailure = try onlyIncompleteCopy(in: root)
            .appendingPathComponent("fail-after.txt")
        try #expect(String(contentsOf: stagedFailure, encoding: .utf8) == "second")
    }

    @Test
    func failedMaximumDepthCopyPreservesInjectedStagingContent() async throws {
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

                var stagedDeepest = try onlyIncompleteCopy(in: root)
                for _ in 1..<maximumCopyDepth {
                    stagedDeepest.appendPathComponent("d", isDirectory: true)
                }

                // Simulate a late same-user mutation inside the app-owned
                // deepest directory. Failed-copy cleanup must preserve it.
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
        var stagedDeepest = try onlyIncompleteCopy(in: root)
        for _ in 1..<maximumCopyDepth {
            stagedDeepest.appendPathComponent("d", isDirectory: true)
        }
        try #expect(
            String(
                contentsOf: stagedDeepest.appendingPathComponent("injected.txt"),
                encoding: .utf8
            ) == "injected"
        )
    }

    @Test
    func lateCopyFailurePreservesStagingWithReadOnlyDirectory() async throws {
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

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Read Only").path
        ))
        let stagedPayload = try onlyIncompleteCopy(in: root)
            .appendingPathComponent("payload.txt")
        try #expect(String(contentsOf: stagedPayload, encoding: .utf8) == "payload")
    }

    @Test
    func protectedRootFailureLeavesVisibleMovableStaging() async throws {
        let container = try makeTemporaryDirectory()
        let root = try makeDirectory(named: "Root", in: container)
        let outside = try makeDirectory(named: "Outside", in: container)
        let trash = try makeDirectory(named: "Trash", in: container)
        let source = try makeFile(
            named: "protected.txt",
            contents: "protected",
            in: outside
        )
        defer {
            try? setFileFlags(0, at: source)
            clearFileFlagsOfImmediateChildren(in: root)
            clearFileFlagsOfImmediateChildren(in: trash)
            try? FileManager.default.removeItem(at: container)
        }
        let protectedFlags = UInt32(UF_HIDDEN) | UInt32(UF_IMMUTABLE)
        try setFileFlags(protectedFlags, at: source)
        let stagedHadProtectedMetadata = LockedBoolRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            mutationHook: { checkpoint, _ in
                guard case .stagedCopyReady = checkpoint else { return }
                let staged = try onlyIncompleteCopy(in: root)
                let flags = try fileFlags(at: staged)
                stagedHadProtectedMetadata.set(flags & protectedFlags != 0)
                throw InjectedCopyError.failed
            },
            trashDirectoryProvider: { _ in trash }
        )

        do {
            _ = try await fileSystem.copyItem(source, to: root, allowedRoot: root)
            Issue.record("Expected the injected copy failure")
        } catch let error as InjectedCopyError {
            #expect(error == .failed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(source.lastPathComponent).path
        ))
        let stagedFile = try onlyIncompleteCopy(in: root)
        #expect(!stagedHadProtectedMetadata.value)
        #expect((try fileFlags(at: stagedFile) & protectedFlags) == 0)
        try #expect(String(contentsOf: stagedFile, encoding: .utf8) == "protected")
        let visibleItems = try await fileSystem.contents(
            of: root,
            showingHiddenFiles: false,
            allowedRoot: root
        )
        #expect(visibleItems.contains { $0.name == stagedFile.lastPathComponent })

        try await fileSystem.moveToTrash(
            stagedFile,
            expectedIdentity: try itemIdentity(at: stagedFile),
            in: root,
            allowedRoot: root
        )

        #expect(!FileManager.default.fileExists(atPath: stagedFile.path))
        try #expect(
            String(
                contentsOf: trash.appendingPathComponent(stagedFile.lastPathComponent),
                encoding: .utf8
            ) == "protected"
        )
    }

    @Test
    func descriptorCopyRejectsSpecialFilesAndPreservesStaging() async throws {
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

        let stagedSource = try onlyIncompleteCopy(in: root)
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(
            atPath: stagedSource.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
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
    func batchTrashPropagatesCancellationFromCurrentItemWithoutStartingAnother() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFile(named: "first.txt", contents: "first", in: root)
        let second = try makeFile(named: "second.txt", contents: "second", in: root)
        let recorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashHandler: { url in
                recorder.append(url)
                throw CancellationError()
            }
        )
        let targets = try [first, second].map { url in
            FlashFileBrowserMutationTarget(
                url: url,
                expectedIdentity: try itemIdentity(at: url)
            )
        }

        do {
            try await fileSystem.moveToTrash(
                targets,
                in: root,
                allowedRoot: root
            )
            Issue.record("Expected the batch Trash operation to be cancelled")
        } catch is CancellationError {
            // Cancellation is intentionally not wrapped as a batch failure.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(recorder.urls == [first])
        try #expect(String(contentsOf: first, encoding: .utf8) == "first")
        try #expect(String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test
    func cancellingBatchTrashAfterACompletedItemPreservesItAndSkipsTheRest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFile(named: "first.txt", contents: "first", in: root)
        let second = try makeFile(named: "second.txt", contents: "second", in: root)
        let third = try makeFile(named: "third.txt", contents: "third", in: root)
        let recorder = LockedURLRecorder()
        let fileSystem = LocalFlashFileBrowserFileSystem(
            trashHandler: { url in
                recorder.append(url)
                try FileManager.default.removeItem(at: url)
                if url.standardizedFileURL == first.standardizedFileURL {
                    // The first mutation has committed. Cancel this child task
                    // before the batch loop can start the next item, without
                    // occupying a cooperative executor thread while waiting.
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            }
        )
        let targets = try [first, second, third].map { url in
            FlashFileBrowserMutationTarget(
                url: url,
                expectedIdentity: try itemIdentity(at: url)
            )
        }

        let trashTask = Task {
            try await fileSystem.moveToTrash(
                targets,
                in: root,
                allowedRoot: root
            )
        }

        do {
            try await trashTask.value
            Issue.record("Expected cancellation before the second Trash item")
        } catch is CancellationError {
            // The first commit remains complete; later items are not started.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(recorder.urls == [first])
        #expect(!FileManager.default.fileExists(atPath: first.path))
        try #expect(String(contentsOf: second, encoding: .utf8) == "second")
        try #expect(String(contentsOf: third, encoding: .utf8) == "third")
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
        let stagedSource = try onlyIncompleteCopy(in: firstRoot)
        try #expect(String(contentsOf: stagedSource, encoding: .utf8) == "source")
    }
}

private extension FlashFileBrowserFileSystemTests {
    func onlyIncompleteCopy(in directory: URL) throws -> URL {
        let stagingNames = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("FLASH Incomplete Copy ") }
        #expect(stagingNames.count == 1)
        let stagingName = try #require(stagingNames.first)
        return directory
            .appendingPathComponent(stagingName)
            .standardizedFileURL
    }

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

    func fileFlags(at url: URL) throws -> UInt32 {
        var metadata = stat()
        let path = FileManager.default.fileSystemRepresentation(withPath: url.path)
        let outcome = FlashFileBrowserDescriptorIO.callCapturingErrno {
            Darwin.lstat(path, &metadata)
        }
        guard outcome.result == 0 else {
            throw FlashFileBrowserDescriptorIO.posixError(outcome.errorCode)
        }
        return metadata.st_flags
    }

    func setFileFlags(_ flags: UInt32, at url: URL) throws {
        let path = FileManager.default.fileSystemRepresentation(withPath: url.path)
        let outcome = FlashFileBrowserDescriptorIO.callCapturingErrno {
            Darwin.chflags(path, flags)
        }
        guard outcome.result == 0 else {
            throw FlashFileBrowserDescriptorIO.posixError(outcome.errorCode)
        }
    }

    func clearFileFlagsOfImmediateChildren(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else { return }
        for name in names {
            try? setFileFlags(0, at: directory.appendingPathComponent(name))
        }
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
