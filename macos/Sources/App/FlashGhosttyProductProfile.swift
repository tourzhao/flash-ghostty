import Foundation

/// Product identity shared by the FLASH-Ghostty app and its bundled helpers.
///
/// Keeping the runtime lookup here prevents helper targets from drifting back
/// to Ghostty's official defaults domain.
enum FlashGhosttyProductProfile {
    static let displayName = "FLASH-Ghostty"
    static let releaseBundleIdentifier = "com.flashghostty.app"
    static let debugBundleIdentifier = "com.flashghostty.app.debug"
    static let uiTestBundleIdentifier = "com.flashghostty.app.debug.ui-tests"
    static let filesystemNamespace = "flash-ghostty"

    static var defaultCustomIconPath: String {
        NSString(
            string: "~/.config/\(filesystemNamespace)/\(displayName).icns"
        ).expandingTildeInPath
    }

    /// Updates remain fail-closed until FLASH-Ghostty owns an appcast and
    /// signing key. Official Ghostty's feed and trust root are not valid for
    /// this separately identified product.
    static let supportsSparkleUpdates = false
    static let sparkleFeedURL: String? = nil

    static var currentBundle: Bundle {
        #if DOCK_TILE_PLUGIN
        Bundle(for: DockTilePlugin.self)
        #else
        Bundle.main
        #endif
    }

    static var defaultsSuiteIdentifier: String {
        defaultsSuiteIdentifier(in: currentBundle)
    }

    static func defaultsSuiteIdentifier(in bundle: Bundle) -> String {
        defaultsSuiteIdentifier(forBundleIdentifier: bundle.bundleIdentifier)
    }

    static func defaultsSuiteIdentifier(forBundleIdentifier bundleIdentifier: String?) -> String {
        if let bundleIdentifier {
            if let uiTestHostIdentifier = uiTestHostIdentifier(
                forBundleIdentifier: bundleIdentifier
            ) {
                return uiTestHostIdentifier
            }

            switch bundleIdentifier {
            case releaseBundleIdentifier, debugBundleIdentifier:
                return bundleIdentifier
            case "\(releaseBundleIdentifier).dock-tile":
                return releaseBundleIdentifier
            case "\(debugBundleIdentifier).dock-tile":
                return debugBundleIdentifier
            default:
                break
            }
        }

        #if DEBUG
        return debugBundleIdentifier
        #else
        return releaseBundleIdentifier
        #endif
    }

    static func namespacedIdentifier(_ component: String) -> String {
        "\(defaultsSuiteIdentifier).\(component)"
    }

    private static func uiTestHostIdentifier(
        forBundleIdentifier bundleIdentifier: String
    ) -> String? {
        let pluginSuffix = ".dock-tile"
        let candidate = bundleIdentifier.hasSuffix(pluginSuffix)
            ? String(bundleIdentifier.dropLast(pluginSuffix.count))
            : bundleIdentifier
        guard candidate == uiTestBundleIdentifier ||
                candidate.hasPrefix("\(uiTestBundleIdentifier).run-") else {
            return nil
        }
        return candidate
    }
}
