import Foundation

extension UserDefaults {
    static var ghosttySuite: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["GHOSTTY_USER_DEFAULTS_SUITE"]
        #else
        nil
        #endif
    }

    /// The persistent domain used by FLASH-Ghostty for this process.
    ///
    /// Normal launches use the app's bundle-scoped standard defaults. UI tests
    /// can opt into an isolated suite through `GHOSTTY_USER_DEFAULTS_SUITE`.
    static var ghosttyPersistentDomainIdentifier: String {
        ghosttySuite ?? FlashGhosttyProductProfile.defaultsSuiteIdentifier
    }

    static var ghostty: UserDefaults {
        ghosttySuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
