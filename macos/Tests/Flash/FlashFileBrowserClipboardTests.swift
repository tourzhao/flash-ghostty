import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite @MainActor
struct FlashFileBrowserClipboardTests {
    @Test
    func fileURLsRoundTripInOrderThroughStandardPasteboardItems() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = URL(fileURLWithPath: "/tmp/Folder With Spaces", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/文档.txt")

        #expect(FlashFileBrowserClipboard.copy([first, second], to: pasteboard))
        #expect(pasteboard.pasteboardItems?.count == 2)
        #expect(
            pasteboard.pasteboardItems?.allSatisfy {
                $0.types.contains(.fileURL)
            } == true
        )
        #expect(
            FlashFileBrowserClipboard.fileURLs(from: pasteboard).map(\.path) ==
                [first.path, second.path]
        )
    }

    @Test
    func copyReplacesExistingClipboardOnlyAfterValidatingEveryURL() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("sentinel", forType: .string)
        let file = URL(fileURLWithPath: "/tmp/file.txt")
        let remote = try #require(URL(string: "https://example.com/file.txt"))

        #expect(!FlashFileBrowserClipboard.copy([], to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "sentinel")
        #expect(!FlashFileBrowserClipboard.copy([file, remote], to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "sentinel")

        #expect(FlashFileBrowserClipboard.copy([file], to: pasteboard))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(FlashFileBrowserClipboard.fileURLs(from: pasteboard) == [file])
    }

    @Test
    func readerIgnoresStringsRemoteURLsAndDuplicateFileURLs() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("not a file URL", forType: .string)
        #expect(FlashFileBrowserClipboard.fileURLs(from: pasteboard).isEmpty)

        pasteboard.clearContents()
        let remote = try #require(URL(string: "https://example.com"))
        let remoteItem = NSPasteboardItem()
        #expect(remoteItem.setString(remote.absoluteString, forType: .URL))
        #expect(pasteboard.writeObjects([remoteItem]))
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(FlashFileBrowserClipboard.fileURLs(from: pasteboard).isEmpty)

        let file = URL(fileURLWithPath: "/tmp/repeated.txt")
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, file as NSURL])
        #expect(FlashFileBrowserClipboard.fileURLs(from: pasteboard) == [file])
    }
}
