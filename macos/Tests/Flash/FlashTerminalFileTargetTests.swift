import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashTerminalFileTargetTests {
    @Test func resolvesAbsoluteAndRelativeFilesAgainstSessionDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.txt")
        try writeFile(file)

        let absolute = FlashTerminalFileTargetResolver.resolve(
            file.path,
            workingDirectory: nil
        )
        #expect(absolute?.lexicalURL.path == file.path)
        #expect(absolute?.kind == .regularFile)
        #expect(absolute?.openSafety == .allowed)

        let relative = FlashTerminalFileTargetResolver.resolve(
            "notes.txt",
            workingDirectory: root.path
        )
        #expect(relative?.lexicalURL.path == file.path)

        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "notes.txt",
                workingDirectory: nil
            ) == nil
        )
    }

    @Test func resolvesLineAndColumnOnlyAfterExactPathMisses() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let file = sourceDirectory.appendingPathComponent("main.swift")
        try writeFile(file)

        let lineOnly = FlashTerminalFileTargetResolver.resolve(
            "Sources/main.swift:42",
            workingDirectory: root.path
        )
        #expect(lineOnly?.lexicalURL.path == file.path)
        #expect(lineOnly?.line == 42)
        #expect(lineOnly?.column == nil)

        let lineAndColumn = FlashTerminalFileTargetResolver.resolve(
            "Sources/main.swift:42:7",
            workingDirectory: root.path
        )
        #expect(lineAndColumn?.lexicalURL.path == file.path)
        #expect(lineAndColumn?.line == 42)
        #expect(lineAndColumn?.column == 7)

        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "Sources/main.swift:0",
                workingDirectory: root.path
            ) == nil
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "Sources/main.swift:1:2:3",
                workingDirectory: root.path
            ) == nil
        )
    }

    @Test func exactFilenameContainingColonWinsOverLocationParsing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("report.swift:42")
        try writeFile(file)

        let target = FlashTerminalFileTargetResolver.resolve(
            "report.swift:42",
            workingDirectory: root.path
        )
        #expect(target?.lexicalURL.path == file.path)
        #expect(target?.line == nil)
        #expect(target?.column == nil)
    }

    @Test func expandsOnlyAllowedHomeAndPwdPrefixes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("readme.md")
        try writeFile(file)

        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "$PWD/readme.md",
                workingDirectory: root.path,
                homeDirectory: "/unused"
            )?.lexicalURL.path == file.path
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "$HOME/readme.md",
                workingDirectory: nil,
                homeDirectory: root.path
            )?.lexicalURL.path == file.path
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "~/readme.md",
                workingDirectory: nil,
                homeDirectory: root.path
            )?.lexicalURL.path == file.path
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "$PROJECT/readme.md",
                workingDirectory: root.path,
                homeDirectory: root.path
            ) == nil
        )
    }

    @Test func acceptsOnlyLocalFileURLs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("image.png")
        try writeFile(file)

        let fileTarget = FlashTerminalFileTargetResolver.resolve(
            file.absoluteString,
            workingDirectory: nil
        )
        #expect(fileTarget?.lexicalURL.path == file.path)

        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "https://example.com/image.png",
                workingDirectory: root.path
            ) == nil
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "file://remote.example\(file.path)",
                workingDirectory: nil
            ) == nil
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                file.absoluteString + "?download=1",
                workingDirectory: nil
            ) == nil
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                "custom-tool://open/\(file.lastPathComponent)",
                workingDirectory: root.path
            ) == nil
        )
    }

    @Test func fileURLCanCarryLineAndColumnSuffixes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("main.swift")
        try writeFile(file)

        let target = FlashTerminalFileTargetResolver.resolve(
            file.absoluteString + ":18:3",
            workingDirectory: nil
        )
        #expect(target?.lexicalURL.path == file.path)
        #expect(target?.line == 18)
        #expect(target?.column == 3)
    }

    @Test func directoriesDiscardLocationMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false
        )

        let target = FlashTerminalFileTargetResolver.resolve(
            "Folder:12",
            workingDirectory: root.path
        )
        #expect(target?.kind == .directory)
        #expect(target?.line == nil)
        #expect(target?.column == nil)
    }

    @Test func executableFilesAndTheirSymlinksAreRevealOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("tool")
        try writeFile(executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let executableTarget = FlashTerminalFileTargetResolver.resolve(
            executable.path,
            workingDirectory: nil
        )
        #expect(executableTarget?.openSafety == .revealOnly)

        let link = root.appendingPathComponent("tool-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: executable
        )
        let linkTarget = FlashTerminalFileTargetResolver.resolve(
            link.path,
            workingDirectory: nil
        )
        #expect(linkTarget?.lexicalURL.path == link.path)
        #expect(linkTarget?.canonicalURL.path == executable.path)
        #expect(linkTarget?.openSafety == .revealOnly)
    }

    @Test func finderAliasesAreRevealOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("payload.command")
        try writeFile(executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let alias = root.appendingPathComponent("notes.txt")
        let bookmark = try executable.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)

        let target = FlashTerminalFileTargetResolver.resolve(
            alias.path,
            workingDirectory: nil
        )
        #expect(target?.lexicalURL.path == alias.path)
        #expect(target?.openSafety == .revealOnly)
    }

    @Test func rejectsUnsafeCharactersBeforeAndAfterURLDecoding() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let newlineFile = root.appendingPathComponent("line\nbreak.txt")
        try writeFile(newlineFile)

        #expect(
            FlashTerminalFileTargetResolver.resolve(
                newlineFile.path,
                workingDirectory: nil
            ) == nil
        )
        #expect(
            FlashTerminalFileTargetResolver.resolve(
                newlineFile.absoluteString,
                workingDirectory: nil
            ) == nil
        )
    }

    @Test func localPathClassificationAvoidsProcessDirectoryFallback() {
        #expect(
            FlashTerminalFileTargetResolver.isPotentialLocalPath(
                "Sources/main.swift:10:2"
            )
        )
        #expect(
            FlashTerminalFileTargetResolver.isPotentialLocalPath(
                "file:///tmp/main.swift"
            )
        )
        #expect(
            !FlashTerminalFileTargetResolver.isPotentialLocalPath(
                "https://example.com"
            )
        )
        #expect(
            !FlashTerminalFileTargetResolver.isPotentialLocalPath(
                "mailto:person@example.com"
            )
        )
        #expect(
            !FlashTerminalFileTargetResolver.isPotentialLocalPath(
                "vscode:open"
            )
        )
        #expect(
            FlashTerminalFileTargetResolver.isPotentialLocalPath(
                "Folder:12"
            )
        )
        #expect(
            FlashTerminalFileTargetResolver.shouldRetryAsURLAfterLocalMiss(
                "Folder:12"
            )
        )
        #expect(
            FlashTerminalFileTargetResolver.isPotentialLocalPath(
                "main.swift:42"
            )
        )
        #expect(
            !FlashTerminalFileTargetResolver.shouldRetryAsURLAfterLocalMiss(
                "main.swift:42"
            )
        )
    }

    @Test func revalidationNeverRetargetsAColonFilename() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let colonFile = root.appendingPathComponent("report.swift:42")
        try writeFile(colonFile)
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                colonFile.path,
                workingDirectory: nil
            )
        )

        try FileManager.default.removeItem(at: colonFile)
        try writeFile(root.appendingPathComponent("report.swift"))

        #expect(FlashTerminalFileTargetResolver.revalidate(initial) == nil)
    }

    @Test @MainActor
    func fileBrowserActivationResolvesOffMainAndDeliversOnMain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("browser-threading.txt")
        try writeFile(file)
        let item = try fileBrowserItem(at: file)
        let observation = FlashTerminalFileActionThreadObservation()
        let queue = DispatchQueue(
            label: "com.flashghostty.tests.file-browser-activation"
        )

        let result = await withCheckedContinuation { continuation in
            FlashFileBrowserActivationExecutor.resolveAllowedTarget(
                item,
                queue: queue,
                using: { url in
                    observation.recordValidation(isMainThread: Thread.isMainThread)
                    return FlashTerminalFileTargetResolver.resolve(
                        url.absoluteString,
                        workingDirectory: nil
                    )
                },
                completion: { target in
                    observation.recordCompletion(isMainThread: Thread.isMainThread)
                    continuation.resume(returning: target)
                }
            )
        }

        #expect(result?.lexicalURL.path == file.path)
        #expect(observation.validationWasOnMainThread == false)
        #expect(observation.completionWasOnMainThread == true)
    }

    @Test func fileBrowserActivationRejectsSamePathReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("browser-replacement.txt")
        try writeFile(file)
        let item = try fileBrowserItem(at: file)
        let retiredFile = root.appendingPathComponent("retired-browser-file.txt")
        try FileManager.default.moveItem(at: file, to: retiredFile)
        try Data("replacement".utf8).write(to: file)

        let result = await withCheckedContinuation { continuation in
            FlashFileBrowserActivationExecutor.resolveAllowedTarget(
                item,
                completion: { continuation.resume(returning: $0) }
            )
        }
        #expect(result == nil)
    }

    @Test func fileBrowserActivationRejectsExecutableFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("browser-tool")
        try writeFile(executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let item = try fileBrowserItem(at: executable)

        let result = await withCheckedContinuation { continuation in
            FlashFileBrowserActivationExecutor.resolveAllowedTarget(
                item,
                completion: { continuation.resume(returning: $0) }
            )
        }
        #expect(result == nil)
    }

    @Test @MainActor
    func actionRevalidationRunsOffMainAndDeliversOnMain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("threading.txt")
        try writeFile(file)
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                file.path,
                workingDirectory: nil
            )
        )
        let observation = FlashTerminalFileActionThreadObservation()
        let queue = DispatchQueue(
            label: "com.flashghostty.tests.terminal-file-action-revalidation"
        )

        let result = await withCheckedContinuation { continuation in
            FlashTerminalFileActionExecutor.revalidate(
                initial,
                queue: queue,
                using: { target in
                    observation.recordValidation(isMainThread: Thread.isMainThread)
                    return target
                },
                completion: { target in
                    observation.recordCompletion(isMainThread: Thread.isMainThread)
                    continuation.resume(returning: target)
                }
            )
        }

        #expect(result == initial)
        #expect(observation.validationWasOnMainThread == false)
        #expect(observation.completionWasOnMainThread == true)
    }

    @Test @MainActor
    func openWithRevalidationRunsOffMainAndDeliversOnMain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("open-with-threading.txt")
        try writeFile(file)
        let target = try #require(
            FlashTerminalFileTargetResolver.resolve(file.path, workingDirectory: nil)
        )
        let application = try makeTestApplication(in: root, name: "Threading")
        let applicationTarget = try #require(
            FlashTerminalFileApplicationTarget(applicationURL: application.url)
        )
        let observation = FlashTerminalFileActionThreadObservation()
        let queue = DispatchQueue(
            label: "com.flashghostty.tests.open-with-revalidation"
        )

        let result = await withCheckedContinuation { continuation in
            FlashTerminalFileActionExecutor.revalidateOpenWith(
                target,
                application: applicationTarget,
                queue: queue,
                using: { current in
                    observation.recordValidation(isMainThread: Thread.isMainThread)
                    return current
                },
                applicationUsing: { current in
                    observation.recordApplicationValidation(
                        isMainThread: Thread.isMainThread
                    )
                    return current
                },
                completion: { currentTarget, currentApplication in
                    observation.recordCompletion(isMainThread: Thread.isMainThread)
                    continuation.resume(returning: (currentTarget, currentApplication))
                }
            )
        }

        #expect(result.0 == target)
        #expect(result.1 == applicationTarget)
        #expect(observation.validationWasOnMainThread == false)
        #expect(observation.applicationValidationWasOnMainThread == false)
        #expect(observation.completionWasOnMainThread == true)
    }

    @Test func openWithRejectsReplacedApplicationExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let application = try makeTestApplication(in: root, name: "Replaceable")
        let initial = try #require(
            FlashTerminalFileApplicationTarget(applicationURL: application.url)
        )
        let retiredExecutable = application.executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("Retired")
        try FileManager.default.moveItem(
            at: application.executableURL,
            to: retiredExecutable
        )
        try writeExecutable(application.executableURL)

        #expect(initial.revalidated() == nil)
    }

    @Test func openWithRejectsInPlaceApplicationExecutableRewrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let application = try makeTestApplication(in: root, name: "Rewritten")
        let initial = try #require(
            FlashTerminalFileApplicationTarget(applicationURL: application.url)
        )
        let before = try executableMutationSnapshot(at: application.executableURL)

        // Keep the inode, size, permissions, generation, and birth time fixed.
        // This models O_TRUNC followed by a same-sized executable rewrite; the
        // executable-only ctime identity must still invalidate the menu item.
        Thread.sleep(forTimeInterval: 0.01)
        let handle = try FileHandle(forWritingTo: application.executableURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("#!/bin/sh\nexit 1\n".utf8))
        try handle.synchronize()
        try handle.close()

        let after = try executableMutationSnapshot(at: application.executableURL)
        #expect(after.device == before.device)
        #expect(after.inode == before.inode)
        #expect(after.generation == before.generation)
        #expect(after.birthtimeSeconds == before.birthtimeSeconds)
        #expect(after.birthtimeNanoseconds == before.birthtimeNanoseconds)
        #expect(after.size == before.size)
        #expect(after.mode == before.mode)
        #expect(
            after.statusChangeSeconds != before.statusChangeSeconds ||
                after.statusChangeNanoseconds != before.statusChangeNanoseconds
        )
        #expect(initial.revalidated() == nil)
    }

    @Test func openWithRejectsSamePathApplicationReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let application = try makeTestApplication(in: root, name: "ReplaceableBundle")
        let initial = try #require(
            FlashTerminalFileApplicationTarget(applicationURL: application.url)
        )
        try FileManager.default.moveItem(
            at: application.url,
            to: root.appendingPathComponent("Retired.app", isDirectory: true)
        )
        _ = try makeTestApplication(in: root, name: "ReplaceableBundle")

        #expect(initial.revalidated() == nil)
    }

    @Test func openWithOmitsApplicationWithoutExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationURL = root.appendingPathComponent(
            "Broken.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(
            FlashTerminalFileApplicationTarget(applicationURL: applicationURL) == nil
        )
    }

    @Test func actionRevalidationRejectsSamePathReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("replace-me.txt")
        try writeFile(file)
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                file.path,
                workingDirectory: nil
            )
        )

        // Keep the old inode alive at another path so the replacement cannot
        // accidentally reuse it. A path/kind-only revalidation would accept
        // this stale menu item; identity-aware revalidation must reject it.
        let retiredFile = root.appendingPathComponent("retired.txt")
        try FileManager.default.moveItem(at: file, to: retiredFile)
        try Data("replacement".utf8).write(to: file)

        let current = await withCheckedContinuation { continuation in
            FlashTerminalFileActionExecutor.revalidate(
                initial,
                completion: { continuation.resume(returning: $0) }
            )
        }
        #expect(current == nil)
    }

    @Test func revalidationRejectsReplacementAfterOriginalInodeIsReleased() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("replace-after-delete.txt")
        try writeFile(file)
        let initialIdentity = try filesystemIdentity(at: file)
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                file.path,
                workingDirectory: nil
            )
        )

        // Releasing the original inode allows APFS to reuse its numeric inode
        // immediately. Generation and birthtime keep that ABA replacement
        // distinguishable even when the legacy device/inode pair collides.
        try FileManager.default.removeItem(at: file)
        try Data("replacement".utf8).write(to: file)
        let replacementIdentity = try filesystemIdentity(at: file)

        #expect(replacementIdentity != initialIdentity)
        if replacementIdentity.hasSameLegacyIdentity(as: initialIdentity) {
            #expect(
                replacementIdentity.generation != initialIdentity.generation ||
                    replacementIdentity.birthtimeSeconds != initialIdentity.birthtimeSeconds ||
                    replacementIdentity.birthtimeNanoseconds !=
                        initialIdentity.birthtimeNanoseconds
            )
        }
        #expect(FlashTerminalFileTargetResolver.revalidate(initial) == nil)
    }

    @Test func revalidationRecomputesOpenSafetyAfterChmod() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("chmod-target.txt")
        try writeFile(file)
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                file.path,
                workingDirectory: nil
            )
        )
        #expect(initial.openSafety == .allowed)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )

        let current = try #require(
            FlashTerminalFileTargetResolver.revalidate(initial)
        )
        #expect(current.hasSameFilesystemIdentity(as: initial))
        #expect(current.openSafety == .revealOnly)
    }

    @Test func actionRevalidationRejectsReplacedSymlinkDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("destination.txt")
        try writeFile(destination)
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: destination
        )
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                link.path,
                workingDirectory: nil
            )
        )

        // The symlink entry and canonical path are unchanged, but the object
        // at the destination is not the object shown when the menu opened.
        let retiredDestination = root.appendingPathComponent("retired-destination.txt")
        try FileManager.default.moveItem(at: destination, to: retiredDestination)
        try Data("replacement".utf8).write(to: destination)

        let current = await withCheckedContinuation { continuation in
            FlashTerminalFileActionExecutor.revalidate(
                initial,
                completion: { continuation.resume(returning: $0) }
            )
        }
        #expect(current == nil)
    }

    @Test func symlinkDestinationBecomingExecutableFailsClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("safe-target.txt")
        try writeFile(destination)
        let link = root.appendingPathComponent("document-link.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: destination
        )
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                link.path,
                workingDirectory: nil
            )
        )
        #expect(initial.openSafety == .allowed)

        try FileManager.default.removeItem(at: destination)
        try Data("#!/bin/sh\n".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )

        #expect(FlashTerminalFileTargetResolver.revalidate(initial) == nil)
    }

    @Test func replacedFinderAliasNeverBecomesOpenable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstPayload = root.appendingPathComponent("first.command")
        let secondPayload = root.appendingPathComponent("second.command")
        try writeFile(firstPayload)
        try writeFile(secondPayload)
        let alias = root.appendingPathComponent("notes.txt")
        try writeAlias(at: alias, destination: firstPayload)
        let initial = try #require(
            FlashTerminalFileTargetResolver.resolve(
                alias.path,
                workingDirectory: nil
            )
        )
        #expect(initial.openSafety == .revealOnly)

        try writeAlias(at: alias, destination: secondPayload)

        if let current = FlashTerminalFileTargetResolver.revalidate(initial) {
            #expect(current.openSafety == .revealOnly)
        }
    }

    @Test func revealMenuFallsBackToFinderOutsideSessionRoot() throws {
        let root = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let insideFile = root.appendingPathComponent("inside.txt")
        let outsideFile = outsideRoot.appendingPathComponent("outside.txt")
        try writeFile(insideFile)
        try writeFile(outsideFile)
        let insideTarget = try #require(
            FlashTerminalFileTargetResolver.resolve(
                insideFile.path,
                workingDirectory: nil
            )
        )
        let outsideTarget = try #require(
            FlashTerminalFileTargetResolver.resolve(
                outsideFile.path,
                workingDirectory: nil
            )
        )

        let insideDestination = FlashTerminalFileActionRevealPolicy.destination(
            for: insideTarget,
            workingDirectory: root.path,
            fileBrowserAvailable: true
        )
        #expect(insideDestination == .fileBrowser)
        #expect(insideDestination.title == "Show in File Browser")

        let outsideDestination = FlashTerminalFileActionRevealPolicy.destination(
            for: outsideTarget,
            workingDirectory: root.path,
            fileBrowserAvailable: true
        )
        #expect(outsideDestination == .finder)
        #expect(outsideDestination.title == "Show in Finder")

        #expect(
            FlashTerminalFileActionRevealPolicy.destination(
                for: insideTarget,
                workingDirectory: root.path,
                fileBrowserAvailable: false
            ) == .finder
        )
    }

    @Test func onlyLatestTerminalFileMenuRequestMayPresent() {
        let gate = FlashTerminalFileActionRequestGate()
        let first = gate.begin()
        #expect(gate.isLatest(first))

        let second = gate.begin()
        #expect(!gate.isLatest(first))
        #expect(gate.isLatest(second))

        let third = gate.begin()
        #expect(!gate.isLatest(first))
        #expect(!gate.isLatest(second))
        #expect(gate.isLatest(third))
    }

    @Test func terminalFileMenuRejectsEveryStaleSourceDimension() {
        let current = terminalFileActionSourceState()
        #expect(current.isCurrent)
        #expect(
            FlashTerminalFileMenuPresentationPolicy.shouldPresent(
                isLatestRequest: true,
                sourceState: current
            )
        )

        let staleStates = [
            terminalFileActionSourceState(surfaceIdentityMatches: false),
            terminalFileActionSourceState(focusedSurfaceMatches: false),
            terminalFileActionSourceState(sessionIsSelected: false),
            terminalFileActionSourceState(windowIdentityMatches: false),
            terminalFileActionSourceState(windowIsVisible: false),
            terminalFileActionSourceState(windowIsSelected: false),
            terminalFileActionSourceState(windowIsKey: false),
        ]
        for state in staleStates {
            #expect(!state.isCurrent)
            #expect(
                !FlashTerminalFileMenuPresentationPolicy.shouldPresent(
                    isLatestRequest: true,
                    sourceState: state
                )
            )
        }
    }

    @Test func fileBrowserRevealSurvivesFocusMoveWithinCapturedSession() {
        let movedFocus = terminalFileActionSourceState(
            focusedSurfaceMatches: false
        )
        #expect(!movedFocus.isCurrent)
        #expect(movedFocus.isValidFileBrowserRevealSource)

        let invalidRevealSources = [
            terminalFileActionSourceState(surfaceIdentityMatches: false),
            terminalFileActionSourceState(sessionIsSelected: false),
            terminalFileActionSourceState(windowIdentityMatches: false),
            terminalFileActionSourceState(windowIsVisible: false),
            terminalFileActionSourceState(windowIsSelected: false),
            terminalFileActionSourceState(windowIsKey: false),
        ]
        for state in invalidRevealSources {
            #expect(!state.isValidFileBrowserRevealSource)
        }
    }

    @Test func staleRequestIsRejectedEvenWhenSourceRemainsCurrent() {
        #expect(
            !FlashTerminalFileMenuPresentationPolicy.shouldPresent(
                isLatestRequest: false,
                sourceState: terminalFileActionSourceState()
            )
        )
        #expect(
            FlashTerminalFileMenuPresentationPolicy.shouldPresent(
                isLatestRequest: true,
                sourceState: nil
            )
        )
        #expect(
            !FlashTerminalFileMenuPresentationPolicy.shouldPresent(
                isLatestRequest: false,
                sourceState: nil
            )
        )
    }

    @Test func quickTerminalRemainsAValidFinderOnlyFileMenuSource() {
        #expect(
            FlashTerminalFileActionSessionPolicy.isSelected(
                capturedSessionID: nil,
                currentSessionID: nil,
                selectedSessionID: nil
            )
        )
    }

    @Test func regularTerminalFileMenuRequiresItsCapturedSelectedSession() {
        let captured = SessionWorkspace.SessionID()
        let other = SessionWorkspace.SessionID()
        #expect(
            FlashTerminalFileActionSessionPolicy.isSelected(
                capturedSessionID: captured,
                currentSessionID: captured,
                selectedSessionID: captured
            )
        )
        #expect(
            !FlashTerminalFileActionSessionPolicy.isSelected(
                capturedSessionID: captured,
                currentSessionID: other,
                selectedSessionID: captured
            )
        )
        #expect(
            !FlashTerminalFileActionSessionPolicy.isSelected(
                capturedSessionID: captured,
                currentSessionID: captured,
                selectedSessionID: other
            )
        )
    }
}

private func terminalFileActionSourceState(
    surfaceIdentityMatches: Bool = true,
    focusedSurfaceMatches: Bool = true,
    sessionIsSelected: Bool = true,
    windowIdentityMatches: Bool = true,
    windowIsVisible: Bool = true,
    windowIsSelected: Bool = true,
    windowIsKey: Bool = true
) -> FlashTerminalFileActionSourceState {
    FlashTerminalFileActionSourceState(
        surfaceIdentityMatches: surfaceIdentityMatches,
        focusedSurfaceMatches: focusedSurfaceMatches,
        sessionIsSelected: sessionIsSelected,
        windowIdentityMatches: windowIdentityMatches,
        windowIsVisible: windowIsVisible,
        windowIsSelected: windowIsSelected,
        windowIsKey: windowIsKey
    )
}

private final class FlashTerminalFileActionThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValidationWasOnMainThread: Bool?
    private var storedCompletionWasOnMainThread: Bool?
    private var storedAppValidationWasOnMainThread: Bool?

    var validationWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValidationWasOnMainThread
    }

    var completionWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletionWasOnMainThread
    }

    var applicationValidationWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedAppValidationWasOnMainThread
    }

    func recordValidation(isMainThread: Bool) {
        lock.lock()
        storedValidationWasOnMainThread = isMainThread
        lock.unlock()
    }

    func recordCompletion(isMainThread: Bool) {
        lock.lock()
        storedCompletionWasOnMainThread = isMainThread
        lock.unlock()
    }

    func recordApplicationValidation(isMainThread: Bool) {
        lock.lock()
        storedAppValidationWasOnMainThread = isMainThread
        lock.unlock()
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
    return url
}

private func writeFile(_ url: URL) throws {
    try Data("test".utf8).write(to: url)
}

private func fileBrowserItem(at url: URL) throws -> FlashFileBrowserItem {
    let identity = try filesystemIdentity(at: url)
    return FlashFileBrowserItem(
        url: url,
        identity: .init(
            device: identity.device,
            inode: identity.inode,
            generation: identity.generation,
            birthtimeSeconds: identity.birthtimeSeconds,
            birthtimeNanoseconds: identity.birthtimeNanoseconds
        ),
        name: url.lastPathComponent,
        isDirectory: false,
        isPackage: false,
        isSymbolicLink: false,
        isHidden: false,
        modificationDate: nil
    )
}

private func makeTestApplication(
    in root: URL,
    name: String
) throws -> (url: URL, executableURL: URL) {
    let applicationURL = root.appendingPathComponent("\(name).app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let executableDirectory = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(
        at: executableDirectory,
        withIntermediateDirectories: true
    )
    let executableURL = executableDirectory.appendingPathComponent(name)
    try writeExecutable(executableURL)

    let info: [String: Any] = [
        "CFBundleExecutable": name,
        "CFBundleIdentifier": "com.flashghostty.tests.\(name.lowercased())",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return (applicationURL, executableURL)
}

private func writeExecutable(_ url: URL) throws {
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private func writeAlias(at url: URL, destination: URL) throws {
    let bookmark = try destination.bookmarkData(
        options: .suitableForBookmarkFile,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
    try URL.writeBookmarkData(bookmark, to: url)
}

private struct TerminalFileIdentitySnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let birthtimeSeconds: Int64
    let birthtimeNanoseconds: Int64

    func hasSameLegacyIdentity(as other: Self) -> Bool {
        device == other.device && inode == other.inode
    }
}

private struct TerminalExecutableMutationSnapshot {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let birthtimeSeconds: Int64
    let birthtimeNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
    let size: Int64
    let mode: UInt32
}

private func filesystemIdentity(at url: URL) throws -> TerminalFileIdentitySnapshot {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else {
        throw CocoaError(.fileNoSuchFile)
    }
    return TerminalFileIdentitySnapshot(
        device: UInt64(truncatingIfNeeded: metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        generation: metadata.st_gen,
        birthtimeSeconds: Int64(metadata.st_birthtimespec.tv_sec),
        birthtimeNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec)
    )
}

private func executableMutationSnapshot(
    at url: URL
) throws -> TerminalExecutableMutationSnapshot {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else {
        throw CocoaError(.fileNoSuchFile)
    }
    return TerminalExecutableMutationSnapshot(
        device: UInt64(truncatingIfNeeded: metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        generation: metadata.st_gen,
        birthtimeSeconds: Int64(metadata.st_birthtimespec.tv_sec),
        birthtimeNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec),
        statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
        statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
        size: Int64(metadata.st_size),
        mode: UInt32(metadata.st_mode)
    )
}
