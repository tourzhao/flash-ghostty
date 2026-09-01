import Foundation

/// Selection and scroll coordinates derived from the list exactly as it is
/// presented. Keeping the row calculation pure prevents sorting from sending
/// the AppKit scroller to a different item than SwiftUI selected.
struct FlashFileBrowserRevealPresentation: Equatable {
    let requestID: UUID
    let directoryPath: String
    let targetItemID: FlashFileBrowserItem.ID
    let selectedItemIDs: Set<FlashFileBrowserItem.ID>
    let rowIndex: Int

    static func resolve(
        requestID: UUID,
        target: FlashFileBrowserItem,
        in presentedItems: [FlashFileBrowserItem]
    ) -> Self? {
        guard let rowIndex = presentedItems.firstIndex(where: {
            $0.id == target.id
        }) else { return nil }

        return .init(
            requestID: requestID,
            directoryPath: FlashFileBrowserPathPolicy.standardized(
                target.url.deletingLastPathComponent()
            ).path,
            targetItemID: target.id,
            selectedItemIDs: [target.id],
            rowIndex: rowIndex
        )
    }

    func validated(
        currentDirectory: URL?,
        presentedItems: [FlashFileBrowserItem]
    ) -> Self? {
        guard let currentDirectory,
              FlashFileBrowserPathPolicy.standardized(currentDirectory).path == directoryPath,
              presentedItems.indices.contains(rowIndex),
              presentedItems[rowIndex].id == targetItemID else { return nil }
        return self
    }
}
