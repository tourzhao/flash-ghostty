import AppKit
import Foundation

extension FlashFileBrowserSidebar {
    func activate(_ item: FlashFileBrowserItem) {
        if item.isNavigableFolder {
            Task { await model.navigate(to: item) }
        } else {
            FlashFileBrowserActivationExecutor.resolveAllowedTarget(item) { target in
                guard let target,
                      NSWorkspace.shared.open(target.canonicalURL) else {
                    NSSound.beep()
                    return
                }
            }
        }
    }

    @MainActor
    func reveal(_ request: FlashFileBrowserRevealRequest) async {
        // Reveal temporarily bypasses search/type filtering for its one target;
        // it must never rewrite the user's persisted filter preference.
        selectedItemIDs.removeAll(keepingCapacity: true)
        revealPresentation = nil
        model.dismissReveal()

        let target = await model.reveal(
            request.lexicalURL,
            refreshCurrentDirectory: false
        )
        guard !Task.isCancelled,
              sessionState.revealRequest?.id == request.id else { return }

        if let target {
            let projectedSnapshot = await presentation.presentRevealedItem(
                target.id,
                items: model.items,
                directory: model.currentDirectory
            )
            guard !Task.isCancelled,
                  sessionState.revealRequest?.id == request.id else { return }
            if let presentation = FlashFileBrowserRevealPresentation.resolve(
                requestID: request.id,
                target: target,
                in: projectedSnapshot?.items ?? []
            ) {
                selectedItemIDs = presentation.selectedItemIDs
                revealPresentation = presentation
            }
        }

        controller.acknowledgeFileBrowserRevealRequest(request.id)
    }

    func footerItemCount(
        visibleItems: [FlashFileBrowserItem],
        selectedItems: [FlashFileBrowserItem]
    ) -> String {
        if !selectedItems.isEmpty {
            return "\(selectedItems.count) of \(visibleItems.count) selected"
        }
        return "\(visibleItems.count) item\(visibleItems.count == 1 ? "" : "s")"
    }

    func copyTitle(for items: [FlashFileBrowserItem]) -> String {
        items.count > 1 ? "Copy \(items.count) Items" : "Copy"
    }

    func trashTitle(for items: [FlashFileBrowserItem]) -> String {
        items.count > 1 ? "Move \(items.count) Items to Trash…" : "Move to Trash…"
    }

    var pasteTitle: String {
        guard let directory = model.currentDirectory else { return "Paste" }
        return "Paste into \(directory.lastPathComponent)"
    }

    func copyFiles(_ items: [FlashFileBrowserItem]) {
        guard FlashFileBrowserClipboard.copy(items.map(\.url)) else {
            NSSound.beep()
            return
        }
    }

    func pasteFiles() {
        guard model.currentDirectory != nil,
              !model.isPerformingOperation else { return }
        let urls = FlashFileBrowserClipboard.fileURLs()
        Task { await model.paste(urls) }
    }

    func presentTrashConfirmation(for items: [FlashFileBrowserItem]) {
        guard !items.isEmpty,
              !model.isPerformingOperation else { return }
        // Context menus must dismiss before an alert can be presented.
        DispatchQueue.main.async {
            dialog = .moveToTrash(items)
        }
    }

    func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            urls.map { $0.standardizedFileURL.path }.joined(separator: "\n"),
            forType: .string
        )
    }
}

/// Resolves a launchable file-browser row away from AppKit's event thread.
///
/// A row can remain visible briefly while an external process replaces its
/// directory entry. Compare the live entry with the identity that was listed,
/// and apply the same executable-file policy used for terminal links before
/// handing anything to Launch Services.
enum FlashFileBrowserActivationExecutor {
    typealias Resolver = @Sendable (URL) -> FlashTerminalFileTarget?
    typealias Completion = @MainActor @Sendable (FlashTerminalFileTarget?) -> Void

    private static let validationQueue = DispatchQueue(
        label: "com.flashghostty.file-browser.activate",
        qos: .userInitiated
    )

    static func resolveAllowedTarget(
        _ item: FlashFileBrowserItem,
        queue: DispatchQueue? = nil,
        using resolver: @escaping Resolver = {
            FlashTerminalFileTargetResolver.resolve(
                $0.absoluteString,
                workingDirectory: nil
            )
        },
        completion: @escaping Completion
    ) {
        (queue ?? validationQueue).async {
            let expectedIdentity = FlashFilesystemIdentity(
                device: item.identity.device,
                inode: item.identity.inode,
                generation: item.identity.generation,
                birthtimeSeconds: item.identity.birthtimeSeconds,
                birthtimeNanoseconds: item.identity.birthtimeNanoseconds
            )
            let expectedKind: FlashTerminalFileTarget.Kind = item.isDirectory
                ? .directory
                : .regularFile
            let current: FlashTerminalFileTarget?
            if let target = resolver(item.url),
               target.lexicalURL.standardizedFileURL.path == item.url.path,
               target.kind == expectedKind,
               target.openSafety == .allowed,
               target.hasLexicalFilesystemIdentity(expectedIdentity) {
                current = target
            } else {
                current = nil
            }
            DispatchQueue.main.async { @MainActor in
                completion(current)
            }
        }
    }
}
