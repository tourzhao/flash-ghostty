import AppKit
import XCTest

final class GhosttySessionRestorationUITests: GhosttyCustomConfigCase {
    private enum TestConfigurationError: Error {
        case invalidRunnerBundleIdentifier(String?)
    }

    private var testRoot: URL!
    private var initialDirectory: URL!
    private var restoredDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fgr-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        let initialDirectory = testRoot.appendingPathComponent(
            "initial",
            isDirectory: true
        )
        let restoredDirectory = testRoot.appendingPathComponent(
            "restored",
            isDirectory: true
        )
        self.testRoot = testRoot
        self.initialDirectory = initialDirectory
        self.restoredDirectory = restoredDirectory

        for directory in [
            initialDirectory,
            restoredDirectory,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("swift".utf8).write(
            to: restoredDirectory.appendingPathComponent("restored.swift")
        )
        try Data("markdown".utf8).write(
            to: restoredDirectory.appendingPathComponent("not-selected.md")
        )

        try updateConfig(
            """
            title = "GhosttySessionRestorationUITests"
            working-directory = \(initialDirectory.path)
            window-save-state = always
            confirm-close-surface = false
            window-position-x = 50
            window-position-y = 50
            """
        )
    }

    override func tearDown() async throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        try await super.tearDown()
    }

    /// Exercises the real AppKit Saved Application State round trip. The app
    /// quits through Command-Q, then a second process resolves the production
    /// restoration prompt and materializes the archived terminal session.
    @MainActor
    func testQuitAndRestorePreservesSessionWorkspace() throws {
        // Avoid natural-language inline-completion UI here. This test targets
        // persistence, while XCTest's synthetic typing can accept or discard
        // macOS predictions differently from physical keyboard input.
        let sessionName = "Restored_Work_Session"
        let defaultsSuite = "\(Self.defaultsSuiteName).Restoration.\(UUID().uuidString)"
        let app = try restorationApplication(defaultsSuite: defaultsSuite)
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        launchFresh(app)

        try renameSelectedSession(to: sessionName, in: app)
        try moveShell(to: restoredDirectory, in: app)
        try selectSwiftFileType(in: app)

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 15),
            "Command-Q must complete so AppKit can finish writing the archive"
        )

        app.launch()

        let restoreButton = restoreButton(in: app)
        guard restoreButton.waitForExistence(timeout: 10) else {
            XCTFail("A saved terminal window must present the launch-wide restore choice")
            return
        }
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(
            app.groups["Terminal pane"].waitForExistence(timeout: 1),
            "New Window must remain gated until the restore choice is resolved"
        )
        restoreButton.click()

        XCTAssertTrue(
            sessionSelector(named: sessionName, in: app)
                .waitForExistence(timeout: 15),
            "The restored sidebar must retain the custom session name"
        )
        XCTAssertTrue(
            waitForWorkingDirectory(restoredDirectory.path, in: app),
            "Restoration must use the shell's last directory, not the configured launch directory"
        )
        try assertShellWorkingDirectory(restoredDirectory, in: app)
        XCTAssertTrue(
            element(selectedSwiftTypeIdentifier, in: app)
                .waitForExistence(timeout: 10),
            "The restored file browser must retain its selected file types"
        )
        XCTAssertTrue(app.buttons["restored.swift"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["not-selected.md"].exists)
    }

    /// AppKit can keep Saved Application State in a daemon-owned container
    /// whose filesystem path is intentionally opaque. Use the production
    /// Start Fresh path to clear stale state from an interrupted prior run
    /// instead of guessing that private path. The dedicated UI-test bundle ID
    /// guarantees this never touches a developer's normal FLASH-Ghostty state.
    @MainActor
    private func launchFresh(_ app: XCUIApplication) {
        app.launch()
        // XCTest deliberately launches the host with LaunchServices'
        // `dontMakeFrontmost` modifier. A normal Finder/Dock launch becomes
        // active automatically, so make that production precondition explicit
        // before waiting for the first terminal-window fallback.
        app.activate()

        let restoreButton = restoreButton(in: app)
        let terminal = app.groups["Terminal pane"]
        let startupExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                restoreButton.exists || terminal.exists
            },
            object: app
        )
        guard XCTWaiter.wait(
            for: [startupExpectation],
            timeout: 10
        ) == .completed else {
            XCTFail("The isolated launch produced neither a terminal nor a restore prompt")
            return
        }

        if restoreButton.exists {
            let startFreshButton = element(
                "session-restoration-prompt.start-fresh",
                in: app
            )
            guard startFreshButton.waitForExistence(timeout: 2) else {
                XCTFail("The restoration prompt did not expose Start Fresh")
                return
            }
            startFreshButton.click()
        }

        guard terminal.waitForExistence(timeout: 10) else {
            XCTFail("The isolated first launch did not create a terminal")
            return
        }
        XCTAssertFalse(
            restoreButton.exists,
            "Start Fresh must dismiss stale UI-test restoration state"
        )
    }

    @MainActor
    private func restorationApplication(defaultsSuite: String) throws -> XCUIApplication {
        let runnerBundleIdentifier = Bundle(for: Self.self).bundleIdentifier
        let runnerSuffix = ".uitests"
        guard let runnerBundleIdentifier,
              runnerBundleIdentifier.hasSuffix(runnerSuffix) else {
            throw TestConfigurationError.invalidRunnerBundleIdentifier(
                runnerBundleIdentifier
            )
        }
        let hostBundleIdentifier = String(
            runnerBundleIdentifier.dropLast(runnerSuffix.count)
        )
        let app = try ghosttyApplication(
            defaultsSuite: defaultsSuite,
            ignoreSavedApplicationState: false,
            bundleIdentifier: hostBundleIdentifier
        )
        app.launchArguments.append(contentsOf: ["-NSQuitAlwaysKeepsWindows", "YES"])
        return app
    }

    @MainActor
    private func renameSelectedSession(
        to name: String,
        in app: XCUIApplication
    ) throws {
        // Activation can invalidate SwiftUI's transient accessibility tree.
        // Activate before resolving the conditional row action, then wait for
        // the post-activation element rather than retaining a stale match.
        app.activate()
        let selectButton = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "terminal-session-sidebar.row.",
                ".select"
            )
        ).firstMatch
        guard selectButton.waitForExistence(timeout: 5) else {
            XCTFail("The initial session did not expose its selection control")
            return
        }
        selectButton.click()

        let renameButton = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "terminal-session-sidebar.row.",
                ".rename"
            )
        ).firstMatch
        guard renameButton.waitForExistence(timeout: 5) else {
            XCTFail("The selected session did not expose its rename control")
            return
        }
        renameButton.click()

        // SwiftUI may expose this control as either a text field or a generic
        // accessibility element while focus is moving into the editor. Match
        // by the stable identifier instead of depending on that transient role.
        let nameField = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "terminal-session-sidebar.row.",
                ".name-field"
            )
        ).firstMatch

        // macOS preserves first-click activation semantics when another app
        // moves to the front between the query and synthesized click. Retry
        // once only if the first click activated the window without invoking
        // the button. A successful first click removes `renameButton`, so this
        // branch cannot toggle or duplicate the rename action.
        if !nameField.waitForExistence(timeout: 2) {
            app.activate()
            guard renameButton.waitForExistence(timeout: 2) else {
                XCTFail("The rename control disappeared before it could be invoked")
                return
            }
            renameButton.click()
        }
        guard nameField.waitForExistence(timeout: 5) else {
            XCTFail("The session name editor did not appear")
            return
        }
        nameField.typeText(name)

        // Click the explicit control so this round trip covers the button path
        // as well as the input-method finalization performed by the product.
        let saveButton = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "terminal-session-sidebar.row.",
                ".save-name"
            )
        ).firstMatch
        guard saveButton.waitForExistence(timeout: 5) else {
            XCTFail("The session name editor did not expose its save control")
            return
        }
        app.activate()
        saveButton.click()
        XCTAssertTrue(sessionSelector(named: name, in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func moveShell(
        to directory: URL,
        in app: XCUIApplication
    ) throws {
        let terminal = app.groups["Terminal pane"]
        terminal.click()
        pasteText(
            "cd \(shellQuoted(directory.path)) && " +
                "printf '\\033]7;file://localhost%s\\007' \"$PWD\"",
            into: terminal
        )
        terminal.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForWorkingDirectory(directory.path, in: app),
            "The terminal did not publish the test's runtime working directory"
        )
        XCTAssertTrue(app.buttons["restored.swift"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["not-selected.md"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func selectSwiftFileType(in app: XCUIApplication) throws {
        let filterButton = element("terminal-file-sidebar.type-filter", in: app)
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.click()

        let swiftMenuItem = app.menuItems[".swift"]
        XCTAssertTrue(swiftMenuItem.waitForExistence(timeout: 5))
        swiftMenuItem.click()

        XCTAssertTrue(
            element(selectedSwiftTypeIdentifier, in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["not-selected.md"].exists)
    }

    @MainActor
    private func waitForWorkingDirectory(
        _ expectedPath: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        let workingDirectory = element(
            "terminal-session-working-directory.text",
            in: app
        )
        let standardizedPath = URL(fileURLWithPath: expectedPath)
            .standardizedFileURL.path
        let predicate = NSPredicate(format: "value == %@", standardizedPath)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: workingDirectory
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func sessionSelector(
        named name: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label == %@", "Select \(name)")
        ).firstMatch
    }

    @MainActor
    private func restoreButton(in app: XCUIApplication) -> XCUIElement {
        element("session-restoration-prompt.restore", in: app)
    }

    /// The working-directory label is restored optimistically from the archive.
    /// Ask the actual child shell to write `$PWD` outside the browser root so
    /// this test also proves the spawned process inherited the restored cwd.
    @MainActor
    private func assertShellWorkingDirectory(
        _ expectedDirectory: URL,
        in app: XCUIApplication
    ) throws {
        let probe = testRoot.appendingPathComponent("actual-shell-cwd.txt")
        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.click()
        pasteText(
            "pwd > \(shellQuoted(probe.path))",
            into: terminal
        )
        terminal.typeKey(.return, modifierFlags: [])

        let predicate = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: probe.path)
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: self
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10),
            .completed,
            "The restored child shell did not write the cwd probe"
        )

        let actual = try String(contentsOf: probe, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: actual).standardizedFileURL.path,
            expectedDirectory.standardizedFileURL.path,
            "The child shell's real cwd must match the restored workspace"
        )
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// XCUI's `typeText` routes through the developer's active input source.
    /// That can turn a shell command into composed CJK text. Paste exact bytes
    /// for terminal commands, then restore every materialized pasteboard type.
    @MainActor
    private func pasteText(_ value: String, into element: XCUIElement) {
        let pasteboard = NSPasteboard.general
        let originalItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
        defer {
            pasteboard.clearContents()
            if let originalItems {
                let restoredItems = originalItems.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values {
                        item.setData(data, forType: type)
                    }
                    return item
                }
                pasteboard.writeObjects(restoredItems)
            }
        }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(value, forType: .string))
        element.typeKey("v", modifierFlags: .command)
    }

    private var selectedSwiftTypeIdentifier: String {
        "terminal-file-sidebar.type-filter.selected.extension:swift"
    }
}
