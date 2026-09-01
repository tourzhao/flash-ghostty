import Darwin
import Foundation

/// Builds immutable browser rows from one already-validated directory
/// descriptor. The actor retains ownership and lifetime of the descriptor.
enum FlashFileBrowserDirectoryReader {
    static func items(
        in descriptor: Int32,
        directoryURL: URL,
        showingHiddenFiles: Bool
    ) throws -> [FlashFileBrowserItem] {
        var items: [FlashFileBrowserItem] = []
        var inspectedEntryCount = 0
        let standardizedDirectoryURL = directoryURL.standardizedFileURL
        try FlashFileBrowserDescriptorIO.forEachDirectoryEntry(in: descriptor) { name in
            inspectedEntryCount += 1
            if inspectedEntryCount.isMultiple(of: 256), Task.isCancelled {
                throw CancellationError()
            }

            guard let metadata = FlashFileBrowserDescriptorIO.entryMetadata(
                named: name,
                in: descriptor
            ) else {
                return
            }

            let isHidden = name.hasPrefix(".") ||
                metadata.st_flags & UInt32(UF_HIDDEN) != 0
            guard showingHiddenFiles || !isHidden else { return }

            let entryType = metadata.st_mode & S_IFMT
            let isSymbolicLink = entryType == S_IFLNK
            let isDirectory: Bool
            if isSymbolicLink,
               let targetMetadata = FlashFileBrowserDescriptorIO.entryMetadata(
                   named: name,
                   in: descriptor,
                   followingSymbolicLinks: true
               ) {
                isDirectory = targetMetadata.st_mode & S_IFMT == S_IFDIR
            } else {
                isDirectory = entryType == S_IFDIR
            }

            items.append(FlashFileBrowserItem(
                standardizedURL: standardizedDirectoryURL.appendingPathComponent(name),
                identity: FlashFileBrowserDescriptorIO.identity(from: metadata),
                name: name,
                isDirectory: isDirectory,
                isPackage: isDirectory && isPackageName(name),
                isSymbolicLink: isSymbolicLink,
                isHidden: isHidden,
                modificationDate: modificationDate(from: metadata)
            ))
        }
        return items
    }

    private static func isPackageName(_ name: String) -> Bool {
        packageExtensions.contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        )
    }

    private static func modificationDate(from metadata: stat) -> Date {
        let seconds = TimeInterval(metadata.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }

    /// Common directory-backed document and application formats Finder opens
    /// as one item. This keeps package classification descriptor-relative;
    /// asking LaunchServices about the mutable pathname would reintroduce the
    /// read race that anchored enumeration is intended to close.
    private static let packageExtensions: Set<String> = [
        "app",
        "appex",
        "bundle",
        "framework",
        "kext",
        "key",
        "numbers",
        "pages",
        "photoslibrary",
        "playground",
        "plugin",
        "prefpane",
        "rtfd",
        "scptd",
        "workflow",
        "xcworkspace",
        "xcodeproj",
        "xpc",
    ]
}
