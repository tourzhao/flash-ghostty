import Foundation

/// Pure selection policy shared by the Finder-style table and unit tests.
enum FlashFileBrowserSelection {
    static func reconciled(
        selectedIDs: Set<FlashFileBrowserItem.ID>,
        availableIDs: [FlashFileBrowserItem.ID]
    ) -> Set<FlashFileBrowserItem.ID> {
        selectedIDs.intersection(availableIDs)
    }

    /// Resolves a complete selection in current table order. A mixed
    /// current/stale selection is rejected rather than silently applying a
    /// batch action to only part of what the user selected.
    static func resolve(
        _ itemIDs: Set<FlashFileBrowserItem.ID>,
        in items: [FlashFileBrowserItem]
    ) -> [FlashFileBrowserItem]? {
        guard !itemIDs.isEmpty else { return nil }
        let result = items.filter { itemIDs.contains($0.id) }
        guard result.count == itemIDs.count else { return nil }
        return result
    }
}
