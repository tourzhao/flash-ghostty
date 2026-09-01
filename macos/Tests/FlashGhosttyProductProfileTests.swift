import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashGhosttyProductProfileTests {
    @Test func bundleMetadataUsesFlashIdentity() {
        #expect(FlashGhosttyProductProfile.displayName == "FLASH-Ghostty")
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ==
                "FLASH-Ghostty"
        )
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ==
                "FLASH-Ghostty"
        )
        #expect(Bundle.main.bundleIdentifier == FlashGhosttyProductProfile.defaultsSuiteIdentifier)
        #expect(FlashGhosttyProductProfile.defaultsSuiteIdentifier.hasPrefix("com.flashghostty.app"))
    }

    @Test func sparkleIsFailClosedWithoutAFlashFeedAndKey() {
        #expect(!FlashGhosttyProductProfile.supportsSparkleUpdates)
        #expect(FlashGhosttyProductProfile.sparkleFeedURL == nil)
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == false
        )
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
    }

    @Test func normalDefaultsUseTheProductBundleDomain() {
        #expect(UserDefaults.ghosttySuite == nil)
        #expect(UserDefaults.ghosttyPersistentDomainIdentifier == Bundle.main.bundleIdentifier)
    }

    @Test func defaultCustomIconUsesTheFlashFilesystemNamespace() {
        #expect(FlashGhosttyProductProfile.filesystemNamespace == "flash-ghostty")
        #expect(
            FlashGhosttyProductProfile.defaultCustomIconPath.hasSuffix(
                "/.config/flash-ghostty/FLASH-Ghostty.icns"
            )
        )
    }

    @Test func dockPluginUsesItsHostApplicationDefaultsDomain() {
        #expect(FlashGhosttyProductProfile.defaultsSuiteIdentifier(
            forBundleIdentifier: "com.flashghostty.app.dock-tile"
        ) == "com.flashghostty.app")
        #expect(FlashGhosttyProductProfile.defaultsSuiteIdentifier(
            forBundleIdentifier: "com.flashghostty.app.debug.dock-tile"
        ) == "com.flashghostty.app.debug")
        #expect(FlashGhosttyProductProfile.defaultsSuiteIdentifier(
            forBundleIdentifier: "com.flashghostty.app.debug.ui-tests"
        ) == "com.flashghostty.app.debug.ui-tests")
        #expect(FlashGhosttyProductProfile.defaultsSuiteIdentifier(
            forBundleIdentifier: "com.flashghostty.app.debug.ui-tests.dock-tile"
        ) == "com.flashghostty.app.debug.ui-tests")
        #expect(FlashGhosttyProductProfile.defaultsSuiteIdentifier(
            forBundleIdentifier: "com.flashghostty.app.debug.ui-tests.run-1234"
        ) == "com.flashghostty.app.debug.ui-tests.run-1234")
        #expect(FlashGhosttyProductProfile.defaultsSuiteIdentifier(
            forBundleIdentifier: "com.flashghostty.app.debug.ui-tests.run-1234.dock-tile"
        ) == "com.flashghostty.app.debug.ui-tests.run-1234")
    }
}
