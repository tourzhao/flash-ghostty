import AppKit
import XCTest

final class GhosttySessionRestorationUITests: GhosttyCustomConfigCase {
    private static let isolatedHostBundlePrefix =
        "com.flashghostty.app.debug.ui-tests.run-"

    private enum TestConfigurationError: Error {
        case invalidRunnerBundleIdentifier(String?)
        case invalidIsolatedHostBundleIdentifier(String)
    }

    private struct Sidebar {
        let toggleIdentifier: String
        let contentIdentifier: String

        static let sessions = Self(
            toggleIdentifier: "terminal-session-sidebar.toggle",
            contentIdentifier: "terminal-session-sidebar"
        )
        static let files = Self(
            toggleIdentifier: "terminal-file-sidebar.toggle",
            contentIdentifier: "terminal-file-sidebar"
        )
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
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        }
        let app = try restorationApplication(defaultsSuite: defaultsSuite)
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        launchFresh(app)

        try renameSession(at: 0, count: 1, to: sessionName, in: app)
        try moveShell(to: restoredDirectory, in: app)
        try selectFileType("swift", in: app)
        XCTAssertTrue(
            waitForFileFilter(
                "swift",
                visibleFile: "restored.swift",
                hiddenFile: "not-selected.md",
                in: app
            ),
            "The selected file-type filter did not finish projecting"
        )

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
            waitForFileFilter(
                "swift",
                visibleFile: "restored.swift",
                hiddenFile: "not-selected.md",
                in: app
            ),
            "The restored file browser must retain its selected file types"
        )
    }

    /// Proves that AppKit's outer Saved Application State preserves native tab
    /// and split topology while each terminal payload restores its own session
    /// state. Shared sidebar visibility is intentionally hidden before quitting
    /// so the selected restored controller must republish it to the workspace.
    @MainActor
    func testQuitAndRestorePreservesTwoSessionWorkspace() throws {
        let sessionNames = ["Restored_Session_A", "Restored_Session_B"]
        let firstFocusedDirectory = testRoot.appendingPathComponent(
            "restored-a-focused",
            isDirectory: true
        )
        let secondDirectory = testRoot.appendingPathComponent(
            "restored-b",
            isDirectory: true
        )
        for directory in [firstFocusedDirectory, secondDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("swift".utf8).write(
            to: firstFocusedDirectory.appendingPathComponent("focused.swift")
        )
        try Data("markdown".utf8).write(
            to: firstFocusedDirectory.appendingPathComponent("not-selected.md")
        )
        try Data("markdown".utf8).write(
            to: secondDirectory.appendingPathComponent("restored.md")
        )
        try Data("swift".utf8).write(
            to: secondDirectory.appendingPathComponent("not-selected.swift")
        )
        let defaultsSuite =
            "\(Self.defaultsSuiteName).MultiRestoration.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        }
        let app = try restorationApplication(defaultsSuite: defaultsSuite)
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        launchFresh(app)

        try renameSession(
            at: 0,
            count: 1,
            to: sessionNames[0],
            in: app
        )
        try moveShell(to: restoredDirectory, in: app)

        let initialTerminal = app.groups["Terminal pane"]
        initialTerminal.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(
            waitForSplitPanes(in: app),
            "Session A must contain two live terminal surfaces before saving"
        )
        XCTAssertTrue(
            waitForTerminalPaneCount(2, in: app),
            "Session A must expose exactly two terminal leaves before saving"
        )
        try moveShell(
            to: firstFocusedDirectory,
            expectedFiles: ["focused.swift", "not-selected.md"],
            paneLabel: "Right pane",
            in: app
        )
        try selectFileType("swift", in: app)
        XCTAssertTrue(
            waitForFileFilter(
                "swift",
                visibleFile: "focused.swift",
                hiddenFile: "not-selected.md",
                in: app
            ),
            "Session A's file-type filter did not finish projecting"
        )

        app.groups["Right pane"].typeKey("t", modifierFlags: .command)
        XCTAssertTrue(
            waitForSessions(count: 2, selectedIndex: 1, in: app),
            "The second native tab must join and select the shared workspace"
        )
        try renameSession(
            at: 1,
            count: 2,
            to: sessionNames[1],
            in: app
        )
        try moveShell(
            to: secondDirectory,
            expectedFiles: ["restored.md", "not-selected.swift"],
            in: app
        )
        try selectFileType("md", in: app)

        selectSession(at: 0, count: 2, in: app)
        XCTAssertTrue(
            waitForSessions(
                names: sessionNames,
                count: 2,
                selectedIndex: 0,
                in: app
            ),
            "The pre-quit workspace must have the expected order and selection"
        )
        XCTAssertTrue(
            waitForWorkingDirectory(firstFocusedDirectory.path, in: app),
            "Session A must save its focused right split"
        )
        setSidebar(.files, visible: false, in: app)
        setSidebar(.sessions, visible: false, in: app)

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 15),
            "Command-Q must complete so AppKit can finish writing both sessions"
        )

        app.launch()
        let restoreButton = restoreButton(in: app)
        guard restoreButton.waitForExistence(timeout: 10) else {
            XCTFail("Two saved sessions must present the launch-wide restore choice")
            return
        }
        restoreButton.click()

        XCTAssertTrue(
            waitForSidebars(visible: false, in: app),
            "The merged restored workspace must retain both hidden sidebars"
        )
        setSidebar(.sessions, visible: true, in: app)
        XCTAssertTrue(
            waitForSidebar(.files, visible: false, in: app),
            "The restored file sidebar must remain hidden after its toggle remounts"
        )
        setSidebar(.files, visible: true, in: app)

        XCTAssertTrue(
            waitForSessions(
                names: sessionNames,
                count: 2,
                selectedIndex: 0,
                in: app
            ),
            "Restoration must retain session count, order, names, and selection"
        )
        XCTAssertTrue(
            waitForSplitPanes(in: app),
            "Session A must restore both sides of its split tree"
        )
        XCTAssertTrue(
            waitForTerminalPaneCount(2, in: app),
            "Session A must restore exactly two terminal leaves"
        )
        try assertRestoredSession(
            at: 0,
            count: 2,
            directory: firstFocusedDirectory,
            fileExtension: "swift",
            visibleFile: "focused.swift",
            hiddenFile: "not-selected.md",
            probeName: "actual-shell-cwd-a.txt",
            paneLabel: "Right pane",
            in: app
        )
        try assertShellWorkingDirectory(
            restoredDirectory,
            probeName: "actual-shell-cwd-a-left.txt",
            paneLabel: "Left pane",
            in: app
        )
        XCTAssertTrue(
            waitForWorkingDirectory(restoredDirectory.path, in: app),
            "Focusing Session A's left split must republish its restored cwd"
        )
        XCTAssertTrue(
            waitForFileFilter(
                "swift",
                visibleFile: "restored.swift",
                hiddenFile: "not-selected.md",
                in: app
            ),
            "Split focus changes must not replace the session-level file filter"
        )
        try assertRestoredSession(
            at: 1,
            count: 2,
            directory: secondDirectory,
            fileExtension: "md",
            visibleFile: "restored.md",
            hiddenFile: "not-selected.swift",
            probeName: "actual-shell-cwd-b.txt",
            in: app
        )
        XCTAssertTrue(
            waitForTerminalPaneCount(1, in: app),
            "Session B must restore as exactly one terminal leaf"
        )
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
        guard hostBundleIdentifier.hasPrefix(Self.isolatedHostBundlePrefix) else {
            throw XCTSkip(
                "Real AppKit restoration tests require macos/build.nu " +
                    "--include-ui-tests so they cannot touch developer saved state"
            )
        }
        let runIdentifier = hostBundleIdentifier.dropFirst(
            Self.isolatedHostBundlePrefix.count
        )
        guard !runIdentifier.isEmpty,
              runIdentifier.utf8.allSatisfy(Self.isValidRunIdentifierByte) else {
            throw TestConfigurationError.invalidIsolatedHostBundleIdentifier(
                hostBundleIdentifier
            )
        }
        let app = try ghosttyApplication(
            defaultsSuite: defaultsSuite,
            ignoreSavedApplicationState: false,
            bundleIdentifier: hostBundleIdentifier
        )
        app.launchArguments.append(contentsOf: ["-NSQuitAlwaysKeepsWindows", "YES"])
        return app
    }

    private static func isValidRunIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 45, 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func renameSession(
        at index: Int,
        count expectedCount: Int,
        to name: String,
        in app: XCUIApplication
    ) throws {
        // Activation can invalidate SwiftUI's transient accessibility tree.
        // Activate before resolving the conditional row action, then wait for
        // the post-activation element rather than retaining a stale match.
        app.activate()
        let selectButton = sessionSelectors(in: app).element(boundBy: index)
        guard selectButton.waitForExistence(timeout: 5) else {
            XCTFail("Session \(index + 1) did not expose its selection control")
            return
        }
        selectButton.click()
        guard waitForSessions(
            count: expectedCount,
            selectedIndex: index,
            in: app
        ) else {
            XCTFail("Session \(index + 1) did not become selected for renaming")
            return
        }

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
        expectedFiles: [String] = ["restored.swift", "not-selected.md"],
        paneLabel: String? = nil,
        in app: XCUIApplication
    ) throws {
        let terminal = terminalPane(labeled: paneLabel, in: app)
        let paneDescription = paneLabel ?? "Terminal pane"
        guard terminal.waitForExistence(timeout: 5) else {
            XCTFail("The terminal pane \(paneDescription) did not appear")
            return
        }
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
        for expectedFile in expectedFiles {
            XCTAssertTrue(
                app.buttons[expectedFile].waitForExistence(timeout: 10),
                "The file browser did not load \(expectedFile) from the new directory"
            )
        }
    }

    @MainActor
    private func selectFileType(
        _ fileExtension: String,
        in app: XCUIApplication
    ) throws {
        let filterButton = element("terminal-file-sidebar.type-filter", in: app)
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.click()

        let menuItem = app.menuItems[".\(fileExtension)"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.click()

        XCTAssertTrue(
            element(selectedFileTypeIdentifier(fileExtension), in: app)
                .waitForExistence(timeout: 5)
        )
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
    private func waitForSplitPanes(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.groups["Left pane"].exists &&
                    app.groups["Right pane"].exists
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForTerminalPaneCount(
        _ expectedCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let terminalPanes = app.groups.matching(
            NSPredicate(format: "label == %@", "Terminal pane")
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                terminalPanes.count == expectedCount
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func sessionSelectors(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "terminal-session-sidebar.row.",
                ".select"
            )
        )
    }

    @MainActor
    private func waitForSessions(
        names: [String]? = nil,
        count expectedCount: Int,
        selectedIndex: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let selectors = self.sessionSelectors(in: app)
                guard selectors.count == expectedCount else { return false }
                if let names {
                    guard names.count == expectedCount else { return false }
                    for (index, name) in names.enumerated() {
                        guard selectors.element(boundBy: index).label ==
                                "Select \(name)" else { return false }
                    }
                }
                for index in 0..<expectedCount {
                    let selector = selectors.element(boundBy: index)
                    let isSelected = (selector.value as? String)?
                        .contains("Selected") == true
                    guard isSelected == (index == selectedIndex) else { return false }
                }
                return true
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func selectSession(
        at index: Int,
        count expectedCount: Int,
        in app: XCUIApplication
    ) {
        let selector = sessionSelectors(in: app).element(boundBy: index)
        guard selector.waitForExistence(timeout: 5) else {
            XCTFail("Session \(index + 1) did not expose its selection control")
            return
        }
        selector.click()
        XCTAssertTrue(
            waitForSessions(
                count: expectedCount,
                selectedIndex: index,
                in: app
            ),
            "Session \(index + 1) did not become selected"
        )
    }

    @MainActor
    private func setSidebar(
        _ sidebar: Sidebar,
        visible isVisible: Bool,
        in app: XCUIApplication
    ) {
        let expectedValue = isVisible ? "Shown" : "Hidden"
        let toggle = element(sidebar.toggleIdentifier, in: app)
        guard toggle.waitForExistence(timeout: 10) else {
            XCTFail("The sidebar toggle \(sidebar.toggleIdentifier) did not appear")
            return
        }
        if toggle.value as? String != expectedValue {
            toggle.click()
        }
        XCTAssertTrue(
            waitForSidebar(sidebar, visible: isVisible, in: app),
            "The sidebar \(sidebar.contentIdentifier) did not become \(expectedValue)"
        )
    }

    @MainActor
    private func waitForSidebar(
        _ sidebar: Sidebar,
        visible isVisible: Bool,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        let expectedValue = isVisible ? "Shown" : "Hidden"
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.element(sidebar.contentIdentifier, in: app).exists == isVisible &&
                    self.element(sidebar.toggleIdentifier, in: app).value as? String ==
                    expectedValue
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForSidebars(
        visible isVisible: Bool,
        in app: XCUIApplication
    ) -> Bool {
        if isVisible {
            return [Sidebar.sessions, .files].allSatisfy {
                waitForSidebar($0, visible: true, in: app)
            }
        }

        // The file-sidebar toggle lives inside the session sidebar, so it is
        // intentionally absent from the accessibility tree while that sidebar
        // is hidden. At this stage, verify both content regions are absent and
        // use the always-mounted titlebar toggle for the shared hidden state.
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !self.element(Sidebar.sessions.contentIdentifier, in: app).exists &&
                    !self.element(Sidebar.files.contentIdentifier, in: app).exists &&
                    self.element(
                        Sidebar.sessions.toggleIdentifier,
                        in: app
                    ).value as? String == "Hidden"
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    @MainActor
    private func waitForFileFilter(
        _ fileExtension: String,
        visibleFile: String,
        hiddenFile: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.element(
                    self.selectedFileTypeIdentifier(fileExtension),
                    in: app
                ).exists &&
                    app.buttons[visibleFile].exists &&
                    !app.buttons[hiddenFile].exists
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func assertRestoredSession(
        at index: Int,
        count expectedCount: Int,
        directory: URL,
        fileExtension: String,
        visibleFile: String,
        hiddenFile: String,
        probeName: String,
        paneLabel: String? = nil,
        in app: XCUIApplication
    ) throws {
        selectSession(at: index, count: expectedCount, in: app)
        XCTAssertTrue(
            waitForSidebars(visible: true, in: app),
            "Shared sidebar visibility did not follow session \(index + 1)"
        )
        XCTAssertTrue(
            waitForWorkingDirectory(directory.path, in: app),
            "Session \(index + 1) did not restore its working directory"
        )
        try assertShellWorkingDirectory(
            directory,
            probeName: probeName,
            paneLabel: paneLabel,
            in: app
        )
        XCTAssertTrue(
            waitForFileFilter(
                fileExtension,
                visibleFile: visibleFile,
                hiddenFile: hiddenFile,
                in: app
            ),
            "Session \(index + 1) did not restore its file-type filter"
        )
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
        probeName: String = "actual-shell-cwd.txt",
        paneLabel: String? = nil,
        in app: XCUIApplication
    ) throws {
        let probe = testRoot.appendingPathComponent(probeName)
        try? FileManager.default.removeItem(at: probe)
        let terminal = terminalPane(labeled: paneLabel, in: app)
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
    private func terminalPane(
        labeled label: String?,
        in app: XCUIApplication
    ) -> XCUIElement {
        guard let label else { return app.groups["Terminal pane"] }
        return app.groups[label]
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

    private func selectedFileTypeIdentifier(_ fileExtension: String) -> String {
        "terminal-file-sidebar.type-filter.selected.extension:\(fileExtension)"
    }
}
