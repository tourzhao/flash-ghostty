import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashGhosttyDefaultConfigTests {
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
