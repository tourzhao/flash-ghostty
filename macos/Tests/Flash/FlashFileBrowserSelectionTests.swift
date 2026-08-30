import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserSelectionTests {
    @Test
    func reconciliationRetainsAvailableIDsAndPrunesStaleOnes() {
        let first = makeItem("first.txt", inode: 1)
        let second = makeItem("second.txt", inode: 2)
        let replacement = makeItem("second.txt", inode: 3)
        let selected = Set([first.id, second.id])

        #expect(
            FlashFileBrowserSelection.reconciled(
                selectedIDs: selected,
                availableIDs: [second.id, first.id]
            ) == selected
        )
        #expect(
            FlashFileBrowserSelection.reconciled(
                selectedIDs: selected,
                availableIDs: [replacement.id, first.id]
            ) == Set([first.id])
        )
        #expect(
            FlashFileBrowserSelection.reconciled(
                selectedIDs: selected,
                availableIDs: []
            ).isEmpty
        )
    }

    @Test
    func resolveIsAllOrNothingAndUsesCurrentTableOrder() {
        let first = makeItem("first.txt", inode: 1)
        let second = makeItem("second.txt", inode: 2)
        let stale = makeItem("stale.txt", inode: 3)

        #expect(
            FlashFileBrowserSelection.resolve(
                Set([first.id, second.id]),
                in: [second, first]
            ) == [second, first]
        )
        #expect(
            FlashFileBrowserSelection.resolve(
                Set([first.id, stale.id]),
                in: [second, first]
            ) == nil
        )
        #expect(FlashFileBrowserSelection.resolve([], in: [first, second]) == nil)
    }

    private func makeItem(_ name: String, inode: UInt64) -> FlashFileBrowserItem {
        FlashFileBrowserItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            identity: .init(device: 1, inode: inode),
            name: name,
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            isHidden: false,
            modificationDate: nil
        )
    }
}
