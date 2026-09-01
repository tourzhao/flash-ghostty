import Foundation

/// App-owned presentation preferences for the working-directory browser.
/// They deliberately live outside terminal configuration because changing
/// them never needs to rebuild a terminal surface.
enum FlashFileBrowserPreferences {
    static let store = UserDefaults.ghostty

    static let widthKey = "FlashFileBrowserWidth"
    static let showingHiddenFilesKey = "FlashFileBrowserShowingHiddenFiles"

    static let defaultWidth = 300.0
    static let widthRange = 240.0...440.0

    static func width(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidth }
        return min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    static var storedWidth: Double {
        let value = (store.object(forKey: widthKey) as? NSNumber)?.doubleValue
            ?? defaultWidth
        return width(value)
    }

    static var storedShowingHiddenFiles: Bool {
        (store.object(forKey: showingHiddenFilesKey) as? NSNumber)?.boolValue
            ?? false
    }
}
