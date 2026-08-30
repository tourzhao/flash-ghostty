import Foundation

/// One exact filename-extension choice in the file browser's type filter.
///
/// Extensions are stored without a leading period and are case-insensitive.
/// Files such as `README` and `.gitignore` share the explicit no-extension
/// choice instead of being folded into an ambiguous "Other" category.
struct FlashFileBrowserFileType:
    Hashable,
    Identifiable,
    Sendable,
    Comparable,
    Codable {
    static let noExtension = FlashFileBrowserFileType(fileExtension: nil)
    /// A conservative restoration bound aligned with macOS `NAME_MAX`.
    static let maximumRestoredExtensionUTF8ByteCount = 255

    let fileExtension: String?

    var isWithinRestorationLimits: Bool {
        guard let fileExtension else { return true }
        return Self.isWithinRestorationLimit(fileExtension)
    }

    init(fileExtension: String?) {
        guard let fileExtension else {
            self.fileExtension = nil
            return
        }

        let trimmed = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLeadingPeriods = trimmed.drop { $0 == "." }
        let normalized = withoutLeadingPeriods.lowercased()
        self.fileExtension = normalized.isEmpty ? nil : normalized
    }

    var id: String {
        fileExtension.map { "extension:\($0)" } ?? "no-extension"
    }

    var displayName: String {
        fileExtension.map { ".\($0)" } ?? "No Extension"
    }

    static func < (
        lhs: FlashFileBrowserFileType,
        rhs: FlashFileBrowserFileType
    ) -> Bool {
        switch (lhs.fileExtension, rhs.fileExtension) {
        case (nil, nil):
            false
        case (nil, _):
            true
        case (_, nil):
            false
        case (.some(let lhsExtension), .some(let rhsExtension)):
            lhsExtension < rhsExtension
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fileExtension
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fileExtension = try container.decodeIfPresent(
            String.self,
            forKey: .fileExtension
        )
        if let fileExtension,
           !Self.isWithinRestorationLimit(fileExtension) {
            throw DecodingError.dataCorruptedError(
                forKey: .fileExtension,
                in: container,
                debugDescription: "Restored file extension exceeds \(Self.maximumRestoredExtensionUTF8ByteCount) UTF-8 bytes"
            )
        }

        let normalized = Self(fileExtension: fileExtension)
        guard normalized.isWithinRestorationLimits else {
            throw DecodingError.dataCorruptedError(
                forKey: .fileExtension,
                in: container,
                debugDescription: "Normalized file extension exceeds \(Self.maximumRestoredExtensionUTF8ByteCount) UTF-8 bytes"
            )
        }
        self = normalized
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fileExtension, forKey: .fileExtension)
    }

    private static func isWithinRestorationLimit(_ value: String) -> Bool {
        value.utf8.prefix(maximumRestoredExtensionUTF8ByteCount + 1).count <=
            maximumRestoredExtensionUTF8ByteCount
    }
}

/// Pure filtering rules shared by the SwiftUI browser and its tests.
enum FlashFileBrowserTypeFilter {
    static func fileType(
        for item: FlashFileBrowserItem
    ) -> FlashFileBrowserFileType? {
        guard !item.isNavigableFolder else { return nil }
        return FlashFileBrowserFileType(fileExtension: item.url.pathExtension)
    }

    /// Returns the exact types represented by non-navigable items, with the
    /// no-extension choice first and all named extensions sorted stably.
    static func availableTypes(
        in items: [FlashFileBrowserItem]
    ) -> [FlashFileBrowserFileType] {
        Set(items.compactMap(fileType(for:))).sorted()
    }

    /// Applies the name query and type choices without changing item order.
    /// An empty type selection means "all types". Navigable folders always
    /// pass the type check so filtering never traps the user in one directory,
    /// but folders must still match a non-empty name query.
    static func visibleItems(
        in items: [FlashFileBrowserItem],
        query: String,
        selectedTypes: Set<FlashFileBrowserFileType>,
        revealing revealedItemID: FlashFileBrowserItem.ID? = nil
    ) -> [FlashFileBrowserItem] {
        let normalizedQuery = normalizedQuery(query)
        return items.filter { item in
            isVisible(
                item,
                normalizedQuery: normalizedQuery,
                selectedTypes: selectedTypes,
                revealing: revealedItemID
            )
        }
    }

    static func isVisible(
        _ item: FlashFileBrowserItem,
        query: String,
        selectedTypes: Set<FlashFileBrowserFileType>,
        revealing revealedItemID: FlashFileBrowserItem.ID? = nil
    ) -> Bool {
        isVisible(
            item,
            normalizedQuery: normalizedQuery(query),
            selectedTypes: selectedTypes,
            revealing: revealedItemID
        )
    }

    static func isVisible(
        _ item: FlashFileBrowserItem,
        normalizedQuery: String,
        selectedTypes: Set<FlashFileBrowserFileType>,
        revealing revealedItemID: FlashFileBrowserItem.ID? = nil
    ) -> Bool {
        // A direct reveal is a temporary presentation override. The persistent
        // type selection and search text resume when the reveal is dismissed.
        if item.id == revealedItemID { return true }

        let matchesDisplayName = normalizedQuery.isEmpty ||
            item.displayName.localizedCaseInsensitiveContains(normalizedQuery)
        let matchesName = matchesDisplayName ||
            (item.name != item.displayName &&
                item.name.localizedCaseInsensitiveContains(normalizedQuery))
        guard matchesName else { return false }

        guard !selectedTypes.isEmpty, !item.isNavigableFolder else {
            return true
        }

        guard let type = fileType(for: item) else { return false }
        return selectedTypes.contains(type)
    }

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
