import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserRevealPresentationTests {
    @Test
    func resolvesSelectionAndRowFromPresentedOrder() throws {
        let first = makeItem("first.swift", inode: 1)
        let target = makeItem("target.swift", inode: 2)
        let last = makeItem("last.swift", inode: 3)
        let requestID = UUID()

        let presentation = try #require(
            FlashFileBrowserRevealPresentation.resolve(
                requestID: requestID,
                target: target,
                in: [last, target, first]
            )
        )

        #expect(presentation.requestID == requestID)
        #expect(presentation.selectedItemIDs == [target.id])
        #expect(presentation.rowIndex == 1)
        #expect(
            presentation.validated(
                currentDirectory: target.url.deletingLastPathComponent(),
                presentedItems: [last, target, first]
            ) == presentation
        )
    }

    @Test
    func rejectsTargetMissingFromPresentedItems() {
        let target = makeItem("target.swift", inode: 1)
        let other = makeItem("other.swift", inode: 2)

        #expect(
            FlashFileBrowserRevealPresentation.resolve(
                requestID: UUID(),
                target: target,
                in: [other]
            ) == nil
        )
    }

    @Test
    func invalidatesStaleDirectoryOrRowOrdering() throws {
        let target = makeItem("target.swift", inode: 1)
        let other = makeItem("other.swift", inode: 2)
        let presentation = try #require(
            FlashFileBrowserRevealPresentation.resolve(
                requestID: UUID(),
                target: target,
                in: [target, other]
            )
        )

        #expect(
            presentation.validated(
                currentDirectory: URL(fileURLWithPath: "/tmp/Other"),
                presentedItems: [target, other]
            ) == nil
        )
        #expect(
            presentation.validated(
                currentDirectory: URL(fileURLWithPath: "/tmp"),
                presentedItems: [other, target]
            ) == nil
        )
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
