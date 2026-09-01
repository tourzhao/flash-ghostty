import AppKit
import Foundation
import SwiftUI

extension FlashFileBrowserSidebar {
    private var sessionFontSize: Double {
        TerminalSessionSidebarPreferences.sessionFontSize(storedSessionFontSize)
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

    @ViewBuilder
    func browserContent(
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
                itemContextMenu(tableItems(for: itemIDs) ?? [])
            } primaryAction: { itemIDs in
                guard let items = tableItems(for: itemIDs),
                      items.count == 1,
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
        for itemIDs: Set<FlashFileBrowserItem.ID>
    ) -> [FlashFileBrowserItem]? {
        presentation.snapshot.resolveSelection(itemIDs)
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

}
