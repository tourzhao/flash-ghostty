//
//  GhosttyCustomConfigCase.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

import XCTest

class GhosttyCustomConfigCase: XCTestCase {
    /// We only want run these UI tests
    /// when testing manually with Xcode IDE
    ///
    /// So that we don't have to wait for each ci check
    /// to run these tedious tests
    override class var defaultTestSuite: XCTestSuite {
        // https://lldb.llvm.org/cpp_reference/PlatformDarwin_8cpp_source.html#:~:text==%20%22-,IDE_DISABLED_OS_ACTIVITY_DT_MODE

        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let isDebugBuild = true
        #if GHOSTTY_RUN_UI_TESTS
        let builtWithCommandLineOptIn = true
        #else
        let builtWithCommandLineOptIn = false
        #endif
        let explicitlyEnabled = builtWithCommandLineOptIn ||
            environment["GHOSTTY_RUN_UI_TESTS"] == "true"
        #else
        // UI tests mutate persistent application state. Release builds always
        // skip them even if an inherited environment variable requests them.
        let isDebugBuild = false
        let explicitlyEnabled = false
        #endif
        if isDebugBuild &&
            (environment["IDE_DISABLED_OS_ACTIVITY_DT_MODE"] != nil || explicitlyEnabled) {
            return XCTestSuite(forTestCaseClass: Self.self)
        } else {
            return XCTestSuite(name: "Skipping \(className())")
        }
    }

    static let defaultsSuiteName: String = "GHOSTTY_UI_TESTS"

    private let configFile: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ghostty")

    /// Zsh-based UI tests must not inherit the developer's startup files.
    /// Besides making the tests machine-dependent, a startup file that touches
    /// a protected folder can leave the login shell blocked behind a TCC prompt.
    private let shellConfigurationDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configFile)
        try? FileManager.default.removeItem(at: shellConfigurationDirectory)
    }

    func updateConfig(_ newConfig: String) throws {
        try FileManager.default.createDirectory(
            at: shellConfigurationDirectory,
            withIntermediateDirectories: true
        )

        try newConfig.write(to: configFile, atomically: true, encoding: .utf8)
    }

    func ghosttyApplication(
        defaultsSuite: String = GhosttyCustomConfigCase.defaultsSuiteName,
        ignoreSavedApplicationState: Bool = true,
        bundleIdentifier: String? = nil
    ) throws -> XCUIApplication {
        let app: XCUIApplication
        if let bundleIdentifier {
            app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        } else {
            app = XCUIApplication()
        }
        if ignoreSavedApplicationState {
            app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        }
        // The persistence arguments belong to AppKit, not Ghostty's config
        // parser. This DEBUG-only test seam prevents them from opening a
        // Configuration Errors window in the launched application.
        app.launchEnvironment["GHOSTTY_TEST_DISABLE_CLI_ARGS"] = "true"
        // Ghostty's zsh integration captures this as the user's ZDOTDIR before it
        // temporarily points zsh at the bundled integration entry point. Do
        // not set SHELL here: desktop launches deliberately resolve their
        // default shell from passwd rather than the process environment.
        app.launchEnvironment["ZDOTDIR"] = shellConfigurationDirectory.path
        app.launchEnvironment["GHOSTTY_CONFIG_PATH"] = configFile.path
        app.launchEnvironment["GHOSTTY_USER_DEFAULTS_SUITE"] = defaultsSuite
        return app
    }
}
