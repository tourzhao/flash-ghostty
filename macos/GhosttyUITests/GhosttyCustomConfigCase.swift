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

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configFile)
    }

    func updateConfig(_ newConfig: String) throws {
        try newConfig.write(to: configFile, atomically: true, encoding: .utf8)
    }

    func ghosttyApplication(defaultsSuite: String = GhosttyCustomConfigCase.defaultsSuiteName) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["GHOSTTY_CONFIG_PATH"] = configFile.path
        app.launchEnvironment["GHOSTTY_USER_DEFAULTS_SUITE"] = defaultsSuite
        return app
    }
}
