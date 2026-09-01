import AppKit
import Foundation

/// Bridges file-browser copy and paste with the macOS system pasteboard.
///
/// Keeping file URLs on the standard pasteboard makes selections compatible
/// with Finder without registering window-wide Command-C/Command-V shortcuts
/// that would conflict with terminal copy and paste.
@MainActor
enum FlashFileBrowserClipboard {
    @discardableResult
    static func copy(
        _ urls: [URL],
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard !urls.isEmpty,
              urls.allSatisfy(\.isFileURL) else { return false }
        let fileURLs = uniqueFileURLs(urls)

        pasteboard.clearContents()
        return pasteboard.writeObjects(fileURLs as [NSURL])
    }

    static func fileURLs(
        from pasteboard: NSPasteboard = .general
    ) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return uniqueFileURLs(objects)
    }

    private static func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var paths: Set<String> = []
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let standardized = url.standardizedFileURL
            guard paths.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}
