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
    ) private var storedSessionFontSize = TerminalSessionSidebarPreferences.defaultSessionFontSize

    @State var searchText = ""
    @State var selectedItemIDs: Set<FlashFileBrowserItem.ID> = []
    @State var sortOrder = FlashFileBrowserListOrdering.defaultSortOrder
    @State var dialog: Dialog?
    @State private var draftName = ""
    @State var revealPresentation: FlashFileBrowserRevealPresentation?
    @FocusState private var focusedControl: FocusTarget?

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

    private enum FocusTarget: Hashable {
        case search
        case fileList
    }

    private var sessionFontSize: Double {
        TerminalSessionSidebarPreferences.sessionFontSize(storedSessionFontSize)
    }

    private var taskIdentity: String {
        let path = directoryForCurrentTask?.standardizedFileURL.path ?? "<nil>"
        let requestID = sessionState.revealRequest?.id.uuidString ?? "<none>"
        return "\(sessionState.sessionID.rawValue.uuidString)|\(path)|\(isSelectedSession)|\(requestID)"
    }

    private var directoryForCurrentTask: URL? {
        sessionState.workingDirectoryURL
    }

    private var isSelectedSession: Bool {
        sessionState.isSelectedSession
    }

    var selectedFileTypes: Set<FlashFileBrowserFileType> {
        sessionState.selectedFileTypes
    }

    private var availableFileTypes: [FlashFileBrowserFileType] {
        presentation.snapshot.availableFileTypes
    }

    private var presentationSort: FlashFileBrowserPresentationSort {
        FlashFileBrowserListOrdering.presentationSort(from: sortOrder)
    }

    private var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !selectedFileTypes.isEmpty
    }

    private func copyCommand(
        for selectedItems: [FlashFileBrowserItem]
    ) -> (() -> Void)? {
        guard !selectedItems.isEmpty else { return nil }
        return { copyFiles(selectedItems) }
    }

    private var pasteCommand: (() -> Void)? {
        guard model.currentDirectory != nil,
              !model.isPerformingOperation else { return nil }
        return pasteFiles
    }

    private var isAtRoot: Bool {
        guard let root = model.sessionRoot,
              let current = model.currentDirectory else { return true }
        return root.standardizedFileURL == current.standardizedFileURL
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
        let presentedItemIDs = snapshot.itemIDs
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
        .onChange(of: model.items) { items in
            presentation.setSource(
                items: items,
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
        .onChange(of: presentedItemIDs) { itemIDs in
            let reconciledSelection = FlashFileBrowserSelection.reconciled(
                selectedIDs: selectedItemIDs,
                availableIDs: itemIDs
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

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemTeal))
                .accessibilityHidden(true)

            Text("Files")
                .font(.system(size: 15, weight: .regular))

            Spacer(minLength: 8)

            browserButton(
                systemName: "folder.badge.plus",
                help: "New Folder",
                identifier: "terminal-file-sidebar.new-folder"
            ) {
                draftName = ""
                dialog = .newFolder
            }
            .disabled(model.currentDirectory == nil || model.isPerformingOperation)

            browserButton(
                systemName: showingHiddenFiles ? "eye.fill" : "eye.slash",
                help: showingHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
                identifier: "terminal-file-sidebar.toggle-hidden"
            ) {
                showingHiddenFiles.toggle()
            }
            .disabled(model.currentDirectory == nil)

            browserButton(
                systemName: "xmark",
                help: "Close File Sidebar",
                identifier: "terminal-file-sidebar.close",
                action: onClose
            )
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var navigationBar: some View {
        HStack(spacing: 4) {
            browserButton(
                systemName: "chevron.left",
                help: "Back",
                identifier: "terminal-file-sidebar.back"
            ) {
                Task { await model.goBack() }
            }
            .disabled(!model.canGoBack || model.isLoading)

            browserButton(
                systemName: "chevron.right",
                help: "Forward",
                identifier: "terminal-file-sidebar.forward"
            ) {
                Task { await model.goForward() }
            }
            .disabled(!model.canGoForward || model.isLoading)

            browserButton(
                systemName: "house",
                help: "Working Directory",
                identifier: "terminal-file-sidebar.root"
            ) {
                Task { await model.goToRoot() }
            }
            .disabled(isAtRoot || model.isLoading)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.currentDirectory?.lastPathComponent ?? "Working Directory")
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let path = model.currentDirectory?.standardizedFileURL.path {
                    Text(path)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(model.currentDirectory?.standardizedFileURL.path ?? "Waiting for directory")

            browserButton(
                systemName: "arrow.clockwise",
                help: "Refresh",
                identifier: "terminal-file-sidebar.refresh"
            ) {
                Task { await model.reload() }
            }
            .disabled(model.currentDirectory == nil || model.isLoading)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    private var searchField: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Filter files", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .regular))
                    .focused($focusedControl, equals: .search)
                    .accessibilityLabel("Filter Files")
                    .accessibilityIdentifier("terminal-file-sidebar.search")

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Name Filter")
                    .accessibilityLabel("Clear Name Filter")
                    .accessibilityIdentifier("terminal-file-sidebar.search.clear")
                }

                typeFilterMenu
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if !selectedFileTypes.isEmpty {
                selectedFileTypeBar
            }
        }
        .padding(.horizontal, 8)
    }

    private var typeFilterMenu: some View {
        Menu {
            if availableFileTypes.isEmpty {
                Text("No File Types")
            } else {
                ForEach(availableFileTypes) { fileType in
                    Toggle(
                        fileType.displayName,
                        isOn: fileTypeSelectionBinding(fileType)
                    )
                }
            }

            Divider()

            Button("Show All File Types") {
                controller.synchronizeFileBrowserSelectedFileTypes([])
            }
            .disabled(selectedFileTypes.isEmpty)
        } label: {
            Image(
                systemName: selectedFileTypes.isEmpty
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(
                selectedFileTypes.isEmpty
                    ? Color.secondary
                    : Color(nsColor: .controlAccentColor)
            )
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by File Type")
        .accessibilityLabel("Filter by File Type")
        .accessibilityValue(
            selectedFileTypes.isEmpty
                ? "All types"
                : "\(selectedFileTypes.count) selected"
        )
        .accessibilityIdentifier("terminal-file-sidebar.type-filter")
    }

    private var selectedFileTypeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(selectedFileTypes.sorted()) { fileType in
                    Button {
                        var selection = selectedFileTypes
                        selection.remove(fileType)
                        controller.synchronizeFileBrowserSelectedFileTypes(selection)
                    } label: {
                        HStack(spacing: 3) {
                            Text(fileType.displayName)
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .regular))
                        }
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .controlAccentColor).opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    Color(nsColor: .controlAccentColor).opacity(0.30),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(fileType.displayName) filter")
                    .accessibilityLabel("Remove \(fileType.displayName) filter")
                    .accessibilityIdentifier(
                        "terminal-file-sidebar.type-filter.selected.\(fileType.id)"
                    )
                }
            }
        }
        .frame(height: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected File Types")
    }

    private func fileTypeSelectionBinding(
        _ fileType: FlashFileBrowserFileType
    ) -> Binding<Bool> {
        Binding(
            get: { selectedFileTypes.contains(fileType) },
            set: { isSelected in
                var selection = selectedFileTypes
                if isSelected {
                    selection.insert(fileType)
                } else {
                    selection.remove(fileType)
                }
                controller.synchronizeFileBrowserSelectedFileTypes(selection)
            }
        )
    }

    @ViewBuilder
    private func browserContent(
        visibleItems: [FlashFileBrowserItem],
        selectedItems: [FlashFileBrowserItem],
        revealPresentation: FlashFileBrowserRevealPresentation?
    ) -> some View {
        if model.sessionRoot == nil {
            unavailableState(
                systemName: "folder.badge.questionmark",
                title: "Waiting for Directory",
                detail: "The file list appears after the shell reports its working directory."
            )
        } else if model.isLoading && model.items.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading files…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(
                visibleItems,
                selection: $selectedItemIDs,
                sortOrder: $sortOrder
            ) {
                TableColumn("Name", value: \.displayName) { item in
                    fileNameCell(item)
                    .accessibilityIdentifier(
                        "terminal-file-sidebar.item.\(item.id)"
                    )
                }
                .width(min: 120, ideal: 190)

                TableColumn(
                    "Date Modified",
                    value: \.listModificationDateSortValue
                ) { item in
                    Text(FlashFileBrowserItemPresentation.modificationDateText(for: item))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 86, ideal: 112)

                TableColumn("Kind") { item in
                    Text(FlashFileBrowserItemPresentation.kindText(for: item))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 72, ideal: 104)
            }
            .contextMenu(forSelectionType: FlashFileBrowserItem.ID.self) { itemIDs in
                itemContextMenu(
                    tableItems(for: itemIDs, in: visibleItems)
                )
            } primaryAction: { itemIDs in
                guard let items = FlashFileBrowserSelection.resolve(
                    itemIDs,
                    in: visibleItems
                ), items.count == 1,
                let item = items.first else { return }
                if selectedItemIDs != itemIDs {
                    selectedItemIDs = itemIDs
                }
                activate(item)
            }
            .font(.system(size: sessionFontSize, weight: .regular))
            .focused($focusedControl, equals: .fileList)
            .accessibilityIdentifier("terminal-file-sidebar.list")
            .onCommand(
                #selector(NSText.copy(_:)),
                perform: copyCommand(for: selectedItems)
            )
            .onCommand(
                #selector(NSText.paste(_:)),
                perform: pasteCommand
            )
            .background {
                FlashFileBrowserCommandMonitor(
                    sessionIsSelected: isSelectedSession,
                    listHasFocus: focusedControl == .fileList,
                    canCopy: !selectedItems.isEmpty,
                    canPaste: model.currentDirectory != nil &&
                        !model.isPerformingOperation,
                    canMoveToTrash: !selectedItems.isEmpty &&
                        !model.isPerformingOperation,
                    copy: { copyFiles(selectedItems) },
                    paste: pasteFiles,
                    moveToTrash: {
                        presentTrashConfirmation(for: selectedItems)
                    },
                    requestListFocus: {
                        focusedControl = .fileList
                    }
                )
            }
            .background {
                FlashFileBrowserTableScroller(
                    presentation: revealPresentation
                )
                .allowsHitTesting(false)
            }
            .overlay {
                if visibleItems.isEmpty {
                    unavailableState(
                        systemName: hasActiveFilters
                            ? "line.3.horizontal.decrease.circle"
                            : "folder",
                        title: hasActiveFilters ? "No Matching Files" : "Folder Is Empty",
                        detail: hasActiveFilters
                            ? "Try different name or file type filters."
                            : "Paste files here or create a new folder."
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func fileNameCell(_ item: FlashFileBrowserItem) -> some View {
        HStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: FlashFileBrowserItemPresentation.systemImageName(for: item))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(FlashFileBrowserItemPresentation.color(for: item))

                if item.isSymbolicLink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 6, weight: .regular))
                        .foregroundStyle(.secondary)
                        .padding(1)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .offset(x: 3, y: 2)
                }
            }
            .frame(width: 19, height: 19)
            .accessibilityHidden(true)

            Text(item.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(item.url.standardizedFileURL.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(
            FlashFileBrowserItemPresentation.accessibilityDetail(for: item)
        )
        .accessibilityHint(item.isNavigableFolder ? "Activate to open folder" : "Activate to open")
        .accessibilityAction {
            activate(item)
        }
    }

    private func tableItems(
        for itemIDs: Set<FlashFileBrowserItem.ID>,
        in visibleItems: [FlashFileBrowserItem]
    ) -> [FlashFileBrowserItem] {
        FlashFileBrowserSelection.resolve(
            itemIDs,
            in: visibleItems
        ) ?? []
    }

    @ViewBuilder
    private func itemContextMenu(_ items: [FlashFileBrowserItem]) -> some View {
        if items.count == 1, let item = items.first {
            Button(item.isNavigableFolder ? "Open Folder" : "Open") {
                activate(item)
            }

            Divider()
        }

        if !items.isEmpty {
            Button(items.count == 1 ? "Show in Finder" : "Show Items in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
            }

            Button(copyTitle(for: items)) {
                copyFiles(items)
            }

            Button(items.count == 1 ? "Copy Path" : "Copy Paths") {
                copyPaths(items.map(\.url))
            }

            Divider()
        }

        Button("Paste") {
            pasteFiles()
        }
        .disabled(model.currentDirectory == nil || model.isPerformingOperation)

        if items.count == 1, let item = items.first {
            Divider()

            Button("Rename…") {
                // Let the context menu dismiss before presenting an alert.
                // AppKit otherwise occasionally drops the request.
                DispatchQueue.main.async {
                    draftName = item.name
                    dialog = .rename(item)
                }
            }
            .disabled(model.isPerformingOperation)

            Button("Duplicate") {
                Task { await model.duplicate(item) }
            }
            .disabled(model.isPerformingOperation)
        }

        if !items.isEmpty {
            Divider()

            Button(trashTitle(for: items), role: .destructive) {
                presentTrashConfirmation(for: items)
            }
            .disabled(model.isPerformingOperation)
        }
    }

    private func footer(
        visibleItems: [FlashFileBrowserItem],
        selectedItems: [FlashFileBrowserItem]
    ) -> some View {
        HStack(spacing: 6) {
            Text(footerItemCount(
                visibleItems: visibleItems,
                selectedItems: selectedItems
            ))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            if model.isLoading || model.isPerformingOperation {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        model.isPerformingOperation ? "Updating Files" : "Loading Files"
                    )
            }

            browserButton(
                systemName: "doc.on.doc",
                help: copyTitle(for: selectedItems),
                identifier: "terminal-file-sidebar.copy"
            ) {
                copyFiles(selectedItems)
            }
            .disabled(selectedItems.isEmpty || model.isPerformingOperation)

            browserButton(
                systemName: "clipboard",
                help: pasteTitle,
                identifier: "terminal-file-sidebar.paste"
            ) {
                pasteFiles()
            }
            .disabled(model.currentDirectory == nil || model.isPerformingOperation)

            browserButton(
                systemName: "trash",
                help: trashTitle(for: selectedItems),
                identifier: "terminal-file-sidebar.trash"
            ) {
                presentTrashConfirmation(for: selectedItems)
            }
            .disabled(selectedItems.isEmpty || model.isPerformingOperation)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func unavailableState(
        systemName: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 13, weight: .regular))

            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 210)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.clearError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss Error")
            .accessibilityLabel("Dismiss Error")
        }
        .padding(8)
        .background(Color(nsColor: .systemOrange).opacity(0.10))
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-file-sidebar.error")
    }

    private func browserButton(
        systemName: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .regular))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.06))
        )
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }

}
