import Foundation

/// One versioned restoration payload for all per-session file-browser state.
/// New file-browser preferences should be added here instead of consuming a
/// new terminal archive version for every field.
struct FlashFileBrowserRestorableState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Bounds both archive work and the restored filter menu to a useful size.
    static let maximumSelectedFileTypeCount = 256

    private static let legacyUnversionedVersion = 0

    let isVisible: Bool
    let selectedFileTypes: [FlashFileBrowserFileType]

    init(
        isVisible: Bool,
        selectedFileTypes: some Sequence<FlashFileBrowserFileType>
    ) {
        self.isVisible = isVisible
        self.selectedFileTypes = Array(
            Set(selectedFileTypes.filter { $0.isWithinRestorationLimits })
                .sorted()
                .prefix(Self.maximumSelectedFileTypeCount)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case isVisible
        case selectedFileTypes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version: Int
        if container.contains(.version) {
            version = try container.decode(Int.self, forKey: .version)
        } else {
            // The nested payload written by local v9 and early v11 builds was
            // structurally identical but did not carry its own version.
            version = Self.legacyUnversionedVersion
        }

        guard version == Self.legacyUnversionedVersion ||
                version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported file-browser restoration version: \(version)"
            )
        }

        self.init(
            isVisible: (try? container.decode(
                Bool.self,
                forKey: .isVisible
            )) ?? true,
            selectedFileTypes: Self.decodeSelectedFileTypes(
                from: container,
                forKey: .selectedFileTypes
            ) ?? []
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(selectedFileTypes, forKey: .selectedFileTypes)
    }

    /// Decodes an optional file-type list without allowing a malformed or
    /// oversized preference to invalidate the surrounding terminal archive.
    static func decodeSelectedFileTypes<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [FlashFileBrowserFileType]? {
        do {
            return try container.decodeIfPresent(
                BoundedSelectedFileTypes.self,
                forKey: key
            )?.values
        } catch {
            return nil
        }
    }

    private struct BoundedSelectedFileTypes: Decodable {
        let values: [FlashFileBrowserFileType]

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            let maximumCount = FlashFileBrowserRestorableState
                .maximumSelectedFileTypeCount
            let tooManyValues = DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "File-browser restoration contains more than \(maximumCount) selected file types"
                )
            )

            if let count = container.count,
               count > maximumCount {
                throw tooManyValues
            }

            var values: [FlashFileBrowserFileType] = []
            values.reserveCapacity(min(
                container.count ?? 0,
                maximumCount
            ))

            var inputCount = 0
            while !container.isAtEnd {
                guard inputCount < maximumCount else {
                    throw tooManyValues
                }
                inputCount += 1

                // A super decoder advances the unkeyed container even when
                // one malformed element cannot be decoded. Valid neighboring
                // filters therefore remain restorable.
                let elementDecoder = try container.superDecoder()
                if let value = try? FlashFileBrowserFileType(
                    from: elementDecoder
                ) {
                    values.append(value)
                }
            }

            self.values = values
        }
    }
}
