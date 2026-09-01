import Foundation

/// Global, user-adjustable presentation preferences for the session sidebar.
/// These are AppKit UI preferences rather than terminal configuration, so they
/// live in Ghostty's UserDefaults domain and apply to every sidebar window.
enum TerminalSessionSidebarPreferences {
    static let store = UserDefaults.ghostty

    static let sessionFontSizeKey = "SessionSidebarSessionFontSize"
    static let sidebarWidthKey = "SessionSidebarWidth"

    static let defaultSessionFontSize = 13.0
    static let defaultSidebarWidth = 260.0
    static let sessionFontSizeRange = 9.0...18.0
    static let sidebarWidthRange = 220.0...360.0
    static let fontSizeStep = 0.5

    static func sessionFontSize(_ value: Double) -> Double {
        sanitized(value, defaultValue: defaultSessionFontSize, range: sessionFontSizeRange)
    }

    static func sidebarWidth(_ value: Double) -> Double {
        sanitized(value, defaultValue: defaultSidebarWidth, range: sidebarWidthRange)
    }

    static var storedSessionFontSize: Double {
        let value = (store.object(forKey: sessionFontSizeKey) as? NSNumber)?.doubleValue
            ?? defaultSessionFontSize
        return sessionFontSize(value)
    }

    static var storedSidebarWidth: Double {
        let value = (store.object(forKey: sidebarWidthKey) as? NSNumber)?.doubleValue
            ?? defaultSidebarWidth
        return sidebarWidth(value)
    }

    static func label(for value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func sanitized(
        _ value: Double,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The name shown in a session-sidebar row. Terminal-generated window titles
/// often contain the working directory, so only an explicit user override is
/// treated as a session name.
enum TerminalSessionName {
    static let unnamed = "Blank"
    static let sidebarWindowTitle = "FLASH-Ghostty"

    static func windowTitle(isSidebar: Bool, regularTitle: String) -> String {
        isSidebar ? sidebarWindowTitle : regularTitle
    }

    static func displayName(for titleOverride: String?) -> String {
        guard let title = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return unnamed }
        return title
    }
}

enum SessionWorkingDirectory {
    static func displayPath(for url: URL?) -> String? {
        guard let url else { return nil }

        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return nil }
        return path
    }
}
