import AppKit
import Foundation
import SwiftUI

extension FlashFileBrowserSidebar {
    private var availableFileTypes: [FlashFileBrowserFileType] {
        presentation.snapshot.availableFileTypes
    }

    private var isAtRoot: Bool {
        guard let root = model.sessionRoot,
              let current = model.currentDirectory else { return true }
        return root.standardizedFileURL == current.standardizedFileURL
    }

    var header: some View {
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

    var navigationBar: some View {
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

    var searchField: some View {
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

    func footer(
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

    func errorBanner(_ message: String) -> some View {
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
