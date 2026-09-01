enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound
    case permissionDenied
    case startupRestorationPending

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: "The Ghostty app isn't properly initialized."
        case .surfaceNotFound: "The terminal no longer exists."
        case .permissionDenied: "Ghostty doesn't allow Shortcuts."
        case .startupRestorationPending:
            "Choose whether to restore previous sessions before creating a terminal."
        }
    }
}
