import AppKit
import Foundation
import SwiftUI

/// A Finder-style list browser for one session's working directory.
///
/// Directory enumeration and mutations are owned by the model so this view
/// never performs filesystem I/O on the render path. Folders open in this same
/// list, keeping the terminal's right sidebar compact at every depth.
struct FlashFileBrowserSidebar: View {
    let controller: TerminalController
    let onClose: () -> Void

    @ObservedObject var sessionState: FlashFileBrowserSessionState
    @StateObject var model: FlashFileBrowserModel
    @StateObject var presentation: FlashFileBrowserPresentationStore

    @AppStorage(
        FlashFileBrowserPreferences.showingHiddenFilesKey,
        store: FlashFileBrowserPreferences.store
    ) var showingHiddenFiles = FlashFileBrowserPreferences.storedShowingHiddenFiles

    @AppStorage(
        TerminalSessionSidebarPreferences.sessionFontSizeKey,
        store: TerminalSessionSidebarPreferences.store
    ) var storedSessionFontSize = TerminalSessionSidebarPreferences.defaultSessionFontSize

    @State var searchText = ""
    @State var selectedItemIDs: Set<FlashFileBrowserItem.ID> = []
    @State var sortOrder = FlashFileBrowserListOrdering.defaultSortOrder
    @State var dialog: Dialog?
    @State var draftName = ""
    @State var revealPresentation: FlashFileBrowserRevealPresentation?
    @FocusState var focusedControl: FocusTarget?

    init(
        controller: TerminalController,
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.onClose = onClose
        _sessionState = ObservedObject(
            wrappedValue: controller.fileBrowserSessionState
        )
        _model = StateObject(
            wrappedValue: FlashFileBrowserModel(
                showingHiddenFiles: FlashFileBrowserPreferences.storedShowingHiddenFiles
            )
        )
        _presentation = StateObject(
            wrappedValue: FlashFileBrowserPresentationStore(
                selectedTypes: controller.fileBrowserSessionState.selectedFileTypes
            )
        )
    }

    enum Dialog: Identifiable {
        case newFolder
        case rename(FlashFileBrowserItem)
        case moveToTrash([FlashFileBrowserItem])

        var id: String {
            switch self {
            case .newFolder:
                "new-folder"
            case .rename(let item):
                "rename-\(item.id)"
            case .moveToTrash(let items):
                "trash-\(items.map(\.id).sorted().joined(separator: "|"))"
            }
        }
    }

    enum FocusTarget: Hashable {
        case search
        case fileList
    }

    private var taskIdentity: String {
        let path = directoryForCurrentTask?.standardizedFileURL.path ?? "<nil>"
        let requestID = sessionState.revealRequest?.id.uuidString ?? "<none>"
        return "\(sessionState.sessionID.rawValue.uuidString)|\(path)|\(isSelectedSession)|\(requestID)"
    }

    private var directoryForCurrentTask: URL? {
        sessionState.workingDirectoryURL
    }

    var isSelectedSession: Bool {
        sessionState.isSelectedSession
    }

    var selectedFileTypes: Set<FlashFileBrowserFileType> {
        sessionState.selectedFileTypes
    }

    private var presentationSort: FlashFileBrowserPresentationSort {
        FlashFileBrowserListOrdering.presentationSort(from: sortOrder)
    }

    private var dialogIsPresented: Binding<Bool> {
        Binding(
            get: { dialog != nil },
            set: { isPresented in
                if !isPresented { dialog = nil }
            }
        )
    }

    private var dialogTitle: String {
        switch dialog {
        case .newFolder:
            "New Folder"
        case .rename:
            "Rename Item"
        case .moveToTrash:
            "Move to Trash?"
        case nil:
            "Files"
        }
    }

    var body: some View {
        let snapshot = presentation.snapshot
        let presentedItems = snapshot.items
        let presentedSelection = snapshot.resolveSelection(selectedItemIDs) ?? []
        let activeRevealPresentation = revealPresentation?.validated(
            currentDirectory: model.currentDirectory,
            presentedItems: presentedItems
        )

        VStack(spacing: 0) {
            header
            navigationBar
            searchField

            Divider()
                .padding(.top, 8)

            browserContent(
                visibleItems: presentedItems,
                selectedItems: presentedSelection,
                revealPresentation: activeRevealPresentation
            )

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }

            footer(
                visibleItems: presentedItems,
                selectedItems: presentedSelection
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: taskIdentity) {
            model.setDirectoryMonitoringEnabled(isSelectedSession)
            guard isSelectedSession else { return }
            let request = sessionState.revealRequest
            await model.synchronize(
                sessionID: sessionState.sessionID,
                directory: sessionState.workingDirectoryURL
            )
            guard !Task.isCancelled,
                  let request,
                  sessionState.revealRequest?.id == request.id else { return }
            await reveal(request)
        }
        .onDisappear {
            model.setDirectoryMonitoringEnabled(false)
        }
        .onChange(of: showingHiddenFiles) { newValue in
            revealPresentation = nil
            presentation.setRevealedItemID(nil)
            Task {
                await model.setShowingHiddenFiles(newValue)
            }
        }
        .onChange(of: model.itemsRevision) { _ in
            presentation.setSource(
                items: model.items,
                directory: model.currentDirectory
            )
        }
        .onChange(of: model.currentDirectory) { directory in
            revealPresentation = nil
            let changedPath = directory.map {
                FlashFileBrowserPathPolicy.standardized($0).path
            }
            let currentPath = model.currentDirectory.map {
                FlashFileBrowserPathPolicy.standardized($0).path
            }
            guard changedPath == currentPath else { return }
            presentation.setDirectory(directory)
        }
        .onChange(of: searchText) { query in
            model.dismissReveal()
            revealPresentation = nil
            presentation.setSearchQuery(query)
        }
        .onChange(of: selectedFileTypes) { selectedTypes in
            model.dismissReveal()
            revealPresentation = nil
            presentation.setSelectedTypes(selectedTypes)
        }
        .onChange(of: presentationSort) { newSort in
            presentation.setSort(newSort)
        }
        .onChange(of: selectedItemIDs) { itemIDs in
            guard let revealPresentation,
                  !itemIDs.contains(revealPresentation.targetItemID) else { return }
            self.revealPresentation = nil
            presentation.setRevealedItemID(nil)
            model.dismissReveal()
        }
        .onChange(of: presentation.snapshotRevision) { _ in
            let reconciledSelection = presentation.snapshot.reconciledSelection(
                selectedItemIDs
            )
            if selectedItemIDs != reconciledSelection {
                selectedItemIDs = reconciledSelection
            }
        }
        .alert(dialogTitle, isPresented: dialogIsPresented) {
            switch dialog {
            case .newFolder:
                TextField("Folder name", text: $draftName)
                Button("Cancel", role: .cancel) {
                    dialog = nil
                }
                Button("Create") {
                    let name = draftName
                    dialog = nil
                    Task { await model.createFolder(named: name) }
                }
            case .rename(let item):
                TextField("New name", text: $draftName)
                Button("Cancel", role: .cancel) {
                    dialog = nil
                }
                Button("Rename") {
                    let name = draftName
                    dialog = nil
                    Task { await model.rename(item, to: name) }
                }
            case .moveToTrash(let items):
                Button("Cancel", role: .cancel) {
                    dialog = nil
                }
                Button("Move to Trash", role: .destructive) {
                    dialog = nil
                    Task { await model.moveToTrash(items) }
                }
            case nil:
                Button("OK", role: .cancel) {}
            }
        } message: {
            if case .moveToTrash(let items) = dialog {
                if items.count == 1, let item = items.first {
                    Text("“\(item.displayName)” can be recovered from the Trash.")
                } else {
                    Text("The \(items.count) selected items can be recovered from the Trash.")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working Directory Files")
        .accessibilityIdentifier("terminal-file-sidebar")
    }

}
