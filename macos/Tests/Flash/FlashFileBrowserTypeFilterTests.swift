import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserTypeFilterTests {
    @Test
    func fileTypesRoundTripAndNormalizeDecodedExtensions() throws {
        let encoded = try JSONEncoder().encode([
            FlashFileBrowserFileType.noExtension,
            FlashFileBrowserFileType(fileExtension: ".SWIFT"),
        ])
        let roundTripped = try JSONDecoder().decode(
            [FlashFileBrowserFileType].self,
            from: encoded
        )

        #expect(roundTripped == [
            .noExtension,
            FlashFileBrowserFileType(fileExtension: "swift"),
        ])

        let unnormalized = Data(
            #"[{"fileExtension":" .SWIFT "},{}]"#.utf8
        )
        let normalized = try JSONDecoder().decode(
            [FlashFileBrowserFileType].self,
            from: unnormalized
        )
        #expect(normalized == [
            FlashFileBrowserFileType(fileExtension: "swift"),
            .noExtension,
        ])
    }

    @Test
    func defaultListOrderShowsNewestFirstWithStableNameTies() {
        let newerDate = Date(timeIntervalSince1970: 200)
        let olderDate = Date(timeIntervalSince1970: 100)
        let items = [
            makeItem("Unknown", inode: 1),
            makeItem("Beta", inode: 2, modificationDate: newerDate),
            makeItem("Older", inode: 3, modificationDate: olderDate),
            makeItem("Alpha", inode: 4, modificationDate: newerDate),
        ]

        #expect(
            items.sorted(using: FlashFileBrowserListOrdering.defaultSortOrder)
                .map(\.name) == ["Alpha", "Beta", "Older", "Unknown"]
        )
    }

    @Test
    func availableTypesNormalizeDeduplicateAndSortExtensions() {
        let items = [
            makeItem("Photo.PNG", inode: 1),
            makeItem("thumbnail.png", inode: 2),
            makeItem("archive.GZ", inode: 3),
            makeItem("README", inode: 4),
            makeItem(".gitignore", inode: 5),
            makeItem("Folder.swift", inode: 6, isDirectory: true),
        ]

        #expect(
            FlashFileBrowserTypeFilter.availableTypes(in: items) == [
                .noExtension,
                FlashFileBrowserFileType(fileExtension: "gz"),
                FlashFileBrowserFileType(fileExtension: ".PNG"),
            ]
        )
        #expect(FlashFileBrowserFileType(fileExtension: " SWIFT ").displayName == ".swift")
        #expect(FlashFileBrowserFileType.noExtension.displayName == "No Extension")
    }

    @Test
    func emptySelectionShowsEveryItemAndPreservesOrder() {
        let items = [
            makeItem("notes.txt", inode: 1),
            makeItem("Sources", inode: 2, isDirectory: true),
            makeItem("main.swift", inode: 3),
        ]

        #expect(
            FlashFileBrowserTypeFilter.visibleItems(
                in: items,
                query: "",
                selectedTypes: []
            ) == items
        )
    }

    @Test
    func selectedTypesFilterFilesButAlwaysRetainNavigableFolders() {
        let folder = makeItem("Examples.txt", inode: 1, isDirectory: true)
        let source = makeItem("main.SWIFT", inode: 2)
        let notes = makeItem("notes.txt", inode: 3)
        let application = makeItem(
            "Preview.app",
            inode: 4,
            isDirectory: true,
            isPackage: true
        )

        #expect(
            FlashFileBrowserTypeFilter.visibleItems(
                in: [folder, source, notes, application],
                query: "",
                selectedTypes: [FlashFileBrowserFileType(fileExtension: "swift")]
            ) == [folder, source]
        )
    }

    @Test
    func noExtensionIsAnIndependentSelectableType() {
        let folder = makeItem("Folder", inode: 1, isDirectory: true)
        let readme = makeItem("README", inode: 2)
        let dotfile = makeItem(".env", inode: 3)
        let markdown = makeItem("README.md", inode: 4)

        #expect(
            FlashFileBrowserTypeFilter.visibleItems(
                in: [folder, readme, dotfile, markdown],
                query: "",
                selectedTypes: [.noExtension]
            ) == [folder, readme, dotfile]
        )
    }

    @Test
    func nameQueryAndTypeSelectionAreCombined() {
        let matchingFolder = makeItem("Source Notes", inode: 1, isDirectory: true)
        let source = makeItem("source.swift", inode: 2)
        let wrongName = makeItem("main.swift", inode: 3)
        let wrongType = makeItem("source.txt", inode: 4)

        #expect(
            FlashFileBrowserTypeFilter.visibleItems(
                in: [matchingFolder, source, wrongName, wrongType],
                query: "  SOURCE  ",
                selectedTypes: [FlashFileBrowserFileType(fileExtension: "SWIFT")]
            ) == [matchingFolder, source]
        )
    }

    @Test
    func queryMatchesEitherFinderLabelOrLiteralFileName() {
        let item = makeItem(
            "raw-report.txt",
            inode: 1,
            displayName: "Localized Report"
        )

        #expect(
            FlashFileBrowserTypeFilter.visibleItems(
                in: [item],
                query: "localized",
                selectedTypes: []
            ) == [item]
        )
        #expect(
            FlashFileBrowserTypeFilter.visibleItems(
                in: [item],
                query: "raw-report",
                selectedTypes: []
            ) == [item]
        )
    }

    @Test
    func revealTemporarilyIncludesTargetWithoutChangingFilterInputs() {
        let source = makeItem("main.swift", inode: 1)
        let target = makeItem("README.md", inode: 2)
        let selectedTypes: Set<FlashFileBrowserFileType> = [
            FlashFileBrowserFileType(fileExtension: "swift"),
        ]

        #expect(
            FlashFileBrowserTypeFilter.visibleItems(
                in: [source, target],
                query: "main",
                selectedTypes: selectedTypes,
                revealing: target.id
            ) == [source, target]
        )
        #expect(selectedTypes == [FlashFileBrowserFileType(fileExtension: "swift")])
    }

    private func makeItem(
        _ name: String,
        inode: UInt64,
        displayName: String? = nil,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        modificationDate: Date? = nil
    ) -> FlashFileBrowserItem {
        FlashFileBrowserItem(
            url: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: isDirectory),
            identity: .init(device: 1, inode: inode),
            name: name,
            displayName: displayName,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: false,
            isHidden: name.hasPrefix("."),
            modificationDate: modificationDate
        )
    }
}
