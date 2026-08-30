import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pure, cached presentation metadata for file-browser rows.
///
/// `UTType.localizedDescription` can consult LaunchServices. Caching by the
/// normalized extension keeps that lookup out of SwiftUI's visible-cell path.
@MainActor
enum FlashFileBrowserItemPresentation {
    private static let kindCache = NSCache<NSString, NSString>()

    static func systemImageName(for item: FlashFileBrowserItem) -> String {
        if item.isNavigableFolder { return "folder.fill" }
        if item.isPackage { return "shippingbox.fill" }

        switch item.url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "webp":
            return "photo"
        case "swift", "zig", "c", "h", "m", "mm", "js", "ts", "py", "rs", "go":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf", "json", "yaml", "yml", "toml":
            return "doc.text"
        default:
            return "doc"
        }
    }

    static func color(for item: FlashFileBrowserItem) -> Color {
        if item.isNavigableFolder { return Color(nsColor: .systemBlue) }
        if item.isPackage { return Color(nsColor: .systemPurple) }
        return .secondary
    }

    static func modificationDateText(for item: FlashFileBrowserItem) -> String {
        guard let date = item.modificationDate else { return "—" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    static func kindText(for item: FlashFileBrowserItem) -> String {
        if item.isNavigableFolder { return "Folder" }
        if item.isPackage {
            return item.url.pathExtension.lowercased() == "app"
                ? "Application"
                : "Package"
        }

        let pathExtension = item.url.pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return "Document" }
        let key = pathExtension as NSString
        if let cached = kindCache.object(forKey: key) {
            return cached as String
        }

        let result = UTType(filenameExtension: pathExtension)?.localizedDescription
            ?? "\(pathExtension.uppercased()) File"
        kindCache.setObject(result as NSString, forKey: key)
        return result
    }

    static func accessibilityDetail(for item: FlashFileBrowserItem) -> String {
        [
            kindText(for: item),
            modificationDateText(for: item),
        ].joined(separator: ", ")
    }
}
