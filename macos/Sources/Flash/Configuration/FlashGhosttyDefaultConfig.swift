import Foundation
import GhosttyKit

/// Loads the fork's product defaults without changing Ghostty's shared
/// configuration defaults.
///
/// The overlay is deliberately loaded before the user's configuration so the
/// user remains authoritative for every setting in the overlay.
enum FlashGhosttyDefaultConfig {
    static let resourceName = "FlashGhosttyDefaults"
    static let resourceExtension = "ghostty"

    @discardableResult
    static func load(
        into config: ghostty_config_t,
        bundle: Bundle = .main
    ) -> Bool {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            Ghostty.logger.critical(
                "FLASH-Ghostty default configuration overlay is missing"
            )
            return false
        }

        ghostty_config_load_file(config, url.path)
        return true
    }
}
