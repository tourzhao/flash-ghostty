import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserSnapshotReconcilerTests {
    @Test
    func unchangedSnapshotDoesNotPublish() async {
        let items = (0..<1_000).map { index in
            makeItem("file\(index).swift", inode: UInt64(index + 1))
        }

        let result = await FlashFileBrowserSnapshotWorker()
            .reconcile(
                loadedItems: items,
                currentItems: items,
                showingHiddenFiles: false,
                transientTarget: nil
            )

        #expect(!result.shouldPublish)
        #expect(result.presentedItems == items)
    }

    @Test
    func changeInLastItemPublishesTheCompleteSnapshot() async {
        let currentItems = (0..<1_000).map { index in
            makeItem("file\(index).swift", inode: UInt64(index + 1))
        }
        var loadedItems = currentItems
        loadedItems[loadedItems.index(before: loadedItems.endIndex)] = makeItem(
            "updated.swift",
            inode: 1_001
        )

        let result = await FlashFileBrowserSnapshotWorker()
            .reconcile(
                loadedItems: loadedItems,
                currentItems: currentItems,
                showingHiddenFiles: false,
                transientTarget: nil
            )

        #expect(result.shouldPublish)
        #expect(result.presentedItems == loadedItems)
    }

    @Test
    func identityChangeAtTheSamePathPublishes() async {
        let current = makeItem("stable.swift", inode: 1)
        let replacement = makeItem("stable.swift", inode: 2)

        let result = await FlashFileBrowserSnapshotWorker()
            .reconcile(
                loadedItems: [replacement],
                currentItems: [current],
                showingHiddenFiles: false,
                transientTarget: nil
            )

        #expect(result.shouldPublish)
        #expect(result.presentedItems == [replacement])
        #expect(result.presentedItems.first?.url == current.url)
        #expect(result.presentedItems.first?.identity != current.identity)
    }

    private func makeItem(
        _ name: String,
        inode: UInt64
    ) -> FlashFileBrowserItem {
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
