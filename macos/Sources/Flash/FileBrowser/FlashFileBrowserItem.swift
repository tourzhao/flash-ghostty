import Foundation

/// Stable identity for one filesystem object while it remains on disk.
///
/// A path alone is not sufficient for destructive operations: another process
/// can replace a directory entry between listing it and the user confirming an
/// action. The device/inode pair lets the filesystem service reject that stale
/// action without resolving symbolic links to their targets.
struct FlashFileBrowserItemIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let birthtimeSeconds: Int64
    let birthtimeNanoseconds: Int64

    init(
        device: UInt64,
        inode: UInt64,
        generation: UInt32 = 0,
        birthtimeSeconds: Int64 = 0,
        birthtimeNanoseconds: Int64 = 0
    ) {
        self.device = device
        self.inode = inode
        self.generation = generation
        self.birthtimeSeconds = birthtimeSeconds
        self.birthtimeNanoseconds = birthtimeNanoseconds
    }
}

/// A direct child displayed by the FLASH working-directory browser.
struct FlashFileBrowserItem: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let identity: FlashFileBrowserItemIdentity
    /// The literal on-disk component used for mutations.
    let name: String
    /// The localized Finder-style label used only for presentation.
    let displayName: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let modificationDate: Date?

    init(
        url: URL,
        identity: FlashFileBrowserItemIdentity,
        name: String,
        displayName: String? = nil,
        isDirectory: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isHidden: Bool,
        modificationDate: Date?
    ) {
        self.init(
            standardizedURL: url.standardizedFileURL,
            identity: identity,
            name: name,
            displayName: displayName,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isHidden: isHidden,
            modificationDate: modificationDate
        )
    }

    /// Fast path for descriptor-backed directory enumeration. The caller must
    /// append a literal child name to a directory URL standardized once at the
    /// enumeration boundary; readdir never yields `.`/`..` or a slash-bearing
    /// component.
    init(
        standardizedURL: URL,
        identity: FlashFileBrowserItemIdentity,
        name: String,
        displayName: String? = nil,
        isDirectory: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isHidden: Bool,
        modificationDate: Date?
    ) {
        self.id = [
            String(identity.device),
            String(identity.inode),
            String(identity.generation),
            String(identity.birthtimeSeconds),
            String(identity.birthtimeNanoseconds),
            standardizedURL.path,
        ].joined(separator: ":")
        self.url = standardizedURL
        self.identity = identity
        self.name = name
        self.displayName = displayName ?? name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
        self.modificationDate = modificationDate
    }

    /// Finder treats packages as launchable items rather than ordinary folders.
    var isNavigableFolder: Bool { isDirectory && !isPackage }
}

/// The initial Finder-list presentation order. The table may replace this
/// when the user clicks a column header, but every newly-created browser starts
/// with the most recently modified items first.
enum FlashFileBrowserListOrdering {
    static var defaultSortOrder: [KeyPathComparator<FlashFileBrowserItem>] {
        [
            KeyPathComparator(\.listModificationDateSortValue, order: .reverse),
            KeyPathComparator(\.displayName),
            KeyPathComparator(\.id),
        ]
    }

    /// Converts SwiftUI's type-erased column comparator into the Sendable sort
    /// state used by the background projection. Only Name and Date Modified
    /// are sortable columns in the file table.
    static func presentationSort(
        from sortOrder: [KeyPathComparator<FlashFileBrowserItem>]
    ) -> FlashFileBrowserPresentationSort {
        guard let primary = sortOrder.first else { return .defaultOrder }

        let direction: FlashFileBrowserPresentationSort.Direction =
            primary.order == .reverse ? .descending : .ascending
        let field: FlashFileBrowserPresentationSort.Field =
            primary.compare(nameProbeA, nameProbeB) == .orderedSame
                ? .modificationDate
                : .name
        return .init(field: field, direction: direction)
    }

    private static let nameProbeA = FlashFileBrowserItem(
        url: URL(fileURLWithPath: "/.flash-sort-probe-file2"),
        identity: .init(device: 0, inode: 1),
        name: "file2",
        isDirectory: false,
        isPackage: false,
        isSymbolicLink: false,
        isHidden: false,
        modificationDate: .distantPast
    )

    private static let nameProbeB = FlashFileBrowserItem(
        url: URL(fileURLWithPath: "/.flash-sort-probe-file10"),
        identity: .init(device: 0, inode: 2),
        name: "file10",
        isDirectory: false,
        isPackage: false,
        isSymbolicLink: false,
        isHidden: false,
        modificationDate: .distantPast
    )
}

extension FlashFileBrowserItem {
    /// Missing dates sort after every dated item in the default reverse order.
    var listModificationDateSortValue: Date {
        modificationDate ?? .distantPast
    }
}

enum FlashFileBrowserPathPolicy {
    /// Returns true when `candidate` is lexically inside `root`.
    ///
    /// Symlinks are deliberately not resolved: rename and trash must act on
    /// the link inside the working directory, not on its target.
    static func contains(_ candidate: URL, in root: URL) -> Bool {
        components(of: candidate).starts(with: components(of: root))
    }

    /// Navigation resolves symlinks so a link cannot silently escape the
    /// session working-directory boundary.
    static func containsResolved(_ candidate: URL, in root: URL) -> Bool {
        components(of: candidate.resolvingSymlinksInPath())
            .starts(with: components(of: root.resolvingSymlinksInPath()))
    }

    static func isDirectChild(_ candidate: URL, of directory: URL) -> Bool {
        standardized(candidate.deletingLastPathComponent()).path == standardized(directory).path
    }

    static func standardized(_ url: URL) -> URL {
        // File URLs with and without a trailing directory slash compare as
        // unequal even when their filesystem paths are identical. Rebuild the
        // URL from its normalized path so shell-reported CWDs and URLs returned
        // by FileManager have one stable representation.
        URL(
            fileURLWithPath: url.standardizedFileURL.path,
            isDirectory: false
        )
    }

    private static func components(of url: URL) -> [String] {
        standardized(url).pathComponents
    }
}
