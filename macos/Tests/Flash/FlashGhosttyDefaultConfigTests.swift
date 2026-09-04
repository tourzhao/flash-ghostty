import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

@Suite
struct FlashGhosttyDefaultConfigTests {
    @Test func preservesClipboardDefaultsThroughCoreConfig() throws {
        let config = try TemporaryConfig("")
        #expect(config.errors.isEmpty)
        #expect(try enumValue("copy-on-select", in: config) == "clipboard")
        #expect(try enumValue("middle-click-action", in: config) == "clipboard-paste")
    }

    @Test func explicitClipboardPreferencesOverrideProductDefaults() throws {
        let config = try TemporaryConfig("""
        copy-on-select = false
        middle-click-action = ignore
        """)
        #expect(config.errors.isEmpty)
        #expect(try enumValue("copy-on-select", in: config) == "none")
        #expect(try enumValue("middle-click-action", in: config) == "ignore")
    }

    @Test func preservesLegacyMacOSClipboardPreferences() throws {
        let config = try TemporaryConfig("""
        copy-on-select = true
        middle-click-action = primary-paste
        """)
        #expect(config.errors.isEmpty)
        #expect(try enumValue("copy-on-select", in: config) == "clipboard")
        #expect(try enumValue("middle-click-action", in: config) == "clipboard-paste")
    }

    private func enumValue(_ key: String, in config: Ghostty.Config) throws -> String {
        let pointer = try #require(config.config)
        var value: UnsafePointer<CChar>?
        #expect(ghostty_config_get(pointer, &value, key, UInt(key.utf8.count)))
        return String(cString: try #require(value))
    }

    @Test func enablesClaudeTerminalOwnedScrollback() throws {
        let resourceURL = try #require(Bundle.main.url(
            forResource: FlashGhosttyDefaultConfig.resourceName,
            withExtension: FlashGhosttyDefaultConfig.resourceExtension
        ))
        let source = try String(contentsOf: resourceURL, encoding: .utf8)

        #expect(source.contains(
            "env = CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1"
        ))
    }
}
