import Foundation

enum FlashFileBrowserFileSystemError: LocalizedError, Equatable {
    case invalidName
    case outsideWorkingDirectory
    case itemIsNotCurrent
    case itemAlreadyExists(String)
    case cannotCreateFolderSafely
    case copySourceUnavailable(String)
    case cannotCopyIntoItself
    case cannotPrepareCopy
    case cannotPrepareTrash
    case workingDirectoryChanged
    case cannotAllocateCopyName
    case batchOperationFailed(completed: Int, total: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Enter a single valid file or folder name."
        case .outsideWorkingDirectory:
            "That location is outside the session working directory."
        case .itemIsNotCurrent:
            "The item changed on disk. Refresh the sidebar and try again."
        case .itemAlreadyExists(let name):
            "An item named “\(name)” already exists."
        case .cannotCreateFolderSafely:
            "This volume or permission mode cannot create the folder safely."
        case .copySourceUnavailable(let name):
            "“\(name)” is no longer available to copy."
        case .cannotCopyIntoItself:
            "A folder cannot be copied into itself."
        case .cannotPrepareCopy:
            "The copy could not be prepared safely."
        case .cannotPrepareTrash:
            "The item could not be moved to Trash safely."
        case .workingDirectoryChanged:
            "The session working directory changed on disk. Re-enter it in the terminal to continue."
        case .cannotAllocateCopyName:
            "A safe name for the copy could not be allocated."
        case .batchOperationFailed(let completed, let total, let reason):
            "Completed \(completed) of \(total) items. \(reason)"
        }
    }
}

struct FlashFileBrowserMutationTarget: Equatable, Sendable {
    let url: URL
    let expectedIdentity: FlashFileBrowserItemIdentity
}

protocol FlashFileBrowserFileSystem: Sendable {
    func bindRoot(_ root: URL) async throws

    func isNavigationAllowed(
        _ directory: URL,
        allowedRoot: URL
    ) async -> Bool

    func contents(
        of directory: URL,
        showingHiddenFiles: Bool,
        allowedRoot: URL
    ) async throws -> [FlashFileBrowserItem]

    func isHidden(
        _ item: URL,
        allowedRoot: URL
    ) async -> Bool

    func createFolder(
        named name: String,
        in directory: URL,
        allowedRoot: URL
    ) async throws -> URL

    func rename(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        to name: String,
        in directory: URL,
        allowedRoot: URL
    ) async throws -> URL

    func duplicate(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in directory: URL,
        allowedRoot: URL
    ) async throws -> URL

    func copyItem(
        _ source: URL,
        to directory: URL,
        allowedRoot: URL
    ) async throws -> URL

    func moveToTrash(
        _ item: URL,
        expectedIdentity: FlashFileBrowserItemIdentity,
        in directory: URL,
        allowedRoot: URL
    ) async throws

    func moveToTrash(
        _ targets: [FlashFileBrowserMutationTarget],
        in directory: URL,
        allowedRoot: URL
    ) async throws
}

extension FlashFileBrowserFileSystem {
    func isHidden(
        _ item: URL,
        allowedRoot: URL
    ) async -> Bool {
        item.lastPathComponent.hasPrefix(".")
    }

    func moveToTrash(
        _ targets: [FlashFileBrowserMutationTarget],
        in directory: URL,
        allowedRoot: URL
    ) async throws {
        var completed = 0
        for target in targets {
            do {
                try Task.checkCancellation()
                try await moveToTrash(
                    target.url,
                    expectedIdentity: target.expectedIdentity,
                    in: directory,
                    allowedRoot: allowedRoot
                )
                completed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FlashFileBrowserFileSystemError.batchOperationFailed(
                    completed: completed,
                    total: targets.count,
                    reason: error.localizedDescription
                )
            }
        }
    }
}
