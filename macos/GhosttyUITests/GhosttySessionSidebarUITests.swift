import XCTest

final class GhosttySessionSidebarUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(
            """
            title = "GhosttySessionSidebarUITests"
            working-directory = /private/tmp
            """
        )
    }

    @MainActor
    func testCleanProductDefaultsExposeSessionSidebar() throws {
        let app = try isolatedGhosttyApplication(testName: #function)
        app.launch()

        XCTAssertTrue(app.groups["Terminal pane"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.groups["terminal-session-sidebar"]
                .waitForExistence(timeout: 2),
            "A clean FLASH-Ghostty configuration must expose the session sidebar group"
        )
        XCTAssertTrue(waitForSessionCount(1, in: app))
        XCTAssertEqual(app.windows.firstMatch.title, "FLASH-Ghostty")
    }

    @MainActor
    func testSessionRowsSurviveNativeTabSelection() throws {
        let app = try isolatedGhosttyApplication(testName: #function)
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 2))
        XCTAssertEqual(app.windows.firstMatch.title, "FLASH-Ghostty")
        XCTAssertTrue(waitForSessionCount(1, in: app))

        XCTAssertTrue(
            waitForWorkingDirectory("/private/tmp", in: app),
            """
            The directory header must leave its loading state after launch; \
            observed accessibility value: \
            \(String(describing: workingDirectoryElement(in: app).value))
            """
        )

        terminal.typeKey("t", modifierFlags: .command)
        terminal.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForSessionCount(3, in: app))

        // Exercise the same path as a user clicking a newly created session.
        // Background native-tab roots retain inert sidebar placeholders. The
        // newly selected root must remount and expose all three live rows.
        let selectors = sessionSelectors(in: app)
        selectors.element(boundBy: 0).click()
        XCTAssertTrue(waitForSelectedSession(at: 0, count: 3, in: app))
        XCTAssertTrue(waitForWorkingDirectory("/private/tmp", in: app))
        sessionSelectors(in: app).element(boundBy: 2).click()
        XCTAssertTrue(waitForSelectedSession(at: 2, count: 3, in: app))
        XCTAssertTrue(waitForWorkingDirectory("/private/tmp", in: app))
        XCTAssertEqual(app.windows.firstMatch.title, "FLASH-Ghostty")

        for index in [1, 2, 3, 1] {
            app.typeKey("\(index)", modifierFlags: .command)
            XCTAssertTrue(
                waitForSelectedSession(at: index - 1, count: 3, in: app),
                "Selecting session \(index) must remount every sidebar row"
            )
        }
    }

    @MainActor
    func testSidebarTogglePersistsAcrossNativeTabSelection() async throws {
        let app = try isolatedGhosttyApplication(testName: #function)
        app.launch()

        let terminal = app.groups["Terminal pane"]
        let window = app.windows.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 2))
        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(waitForSessionCount(1, in: app))

        terminal.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForSessionCount(2, in: app))

        let initialWindowFrame = window.frame
        let initialSidebarWidth = sessionSelectors(in: app).firstMatch.frame.width
        XCTAssertGreaterThan(initialSidebarWidth, 0)

        sidebarToggle(in: app).click()
        XCTAssertTrue(waitForSessionCount(0, in: app))
        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(terminal.waitForExistence(timeout: 2))
        XCTAssertEqual(
            window.frame,
            initialWindowFrame,
            "Hiding the sidebar must give its space to the terminal without resizing the window"
        )

        // A session created while the sidebar is hidden must inherit the
        // logical window group's state instead of flashing the sidebar back on.
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sessionSelectors(in: app).count, 0)
        XCTAssertTrue(sidebarToggle(in: app).isHittable)

        // Each session is backed by a separate native tab window. The hidden
        // state and the titlebar control must follow selection to every one.
        for index in [1, 2, 3] {
            app.typeKey("\(index)", modifierFlags: .command)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(sessionSelectors(in: app).count, 0)
            XCTAssertTrue(
                sidebarToggle(in: app).isHittable,
                "The sidebar toggle must remain available after selecting session \(index)"
            )
            XCTAssertTrue(app.groups["Terminal pane"].exists)
        }

        sidebarToggle(in: app).click()
        XCTAssertTrue(waitForSessionCount(3, in: app))
        XCTAssertEqual(
            sessionSelectors(in: app).firstMatch.frame.width,
            initialSidebarWidth,
            accuracy: 1,
            "Showing the sidebar must restore its previous width"
        )
        XCTAssertEqual(window.frame, initialWindowFrame)
    }

    @MainActor
    func testViewMenuAndKeyboardShortcutTrackSidebarVisibility() throws {
        let app = try isolatedGhosttyApplication(testName: #function)
        app.launch()

        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(waitForSessionCount(1, in: app))
        XCTAssertTrue(openViewMenu(in: app))
        XCTAssertTrue(app.menuItems["Hide Sidebar"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(waitForSessionCount(0, in: app))
        XCTAssertTrue(sidebarToggle(in: app).exists)

        XCTAssertTrue(openViewMenu(in: app))
        let showSidebar = app.menuItems["Show Sidebar"]
        XCTAssertTrue(showSidebar.waitForExistence(timeout: 2))
        showSidebar.click()

        XCTAssertTrue(waitForSessionCount(1, in: app))
        XCTAssertTrue(openViewMenu(in: app))
        XCTAssertTrue(app.menuItems["Hide Sidebar"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func waitForSessionCount(
        _ expectedCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        // XCUIElementQuery.count is a cross-process accessibility snapshot.
        // A debug build with both sidebars visible can take longer than two
        // seconds to complete the first snapshot, so a shorter waiter cancels
        // a query that would otherwise return the correct row count.
        let predicate = NSPredicate { _, _ in
            self.sessionSelectors(in: app).count == expectedCount
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForSelectedSession(
        at index: Int,
        count expectedCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            let selectors = self.sessionSelectors(in: app)
            guard selectors.count == expectedCount else { return false }
            return (selectors.element(boundBy: index).value as? String)?
                .contains("Selected") == true
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForWorkingDirectory(
        _ expectedPath: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        // The app can mount its AX tree before zsh integration publishes the
        // first OSC 7 report. Match the cold-start budget used by the file
        // browser and restoration suites while still failing a missing report.
        // Query the leaf by its unique identifier. A label lookup can still
        // match the text after SwiftUI has propagated an ancestor identifier,
        // masking a broken accessibility hierarchy.
        let element = workingDirectoryElement(in: app)
        // The product intentionally displays a standardized file URL. On
        // macOS, the system alias `/private/tmp` canonicalizes to `/tmp`.
        let expectedValue = URL(fileURLWithPath: expectedPath)
            .standardizedFileURL.path
        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func workingDirectoryElement(in app: XCUIApplication) -> XCUIElement {
        element(
            withIdentifier: "terminal-session-working-directory.text",
            in: app
        )
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
    private func isolatedGhosttyApplication(testName: String) throws -> XCUIApplication {
        try ghosttyApplication(
            defaultsSuite: "\(Self.defaultsSuiteName).\(testName).\(UUID().uuidString)"
        )
    }

    @MainActor
    private func sidebarToggle(in app: XCUIApplication) -> XCUIElement {
        element(withIdentifier: "terminal-session-sidebar.toggle", in: app)
    }

    @MainActor
    private func element(
        withIdentifier identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    @MainActor
    private func openViewMenu(in app: XCUIApplication) -> Bool {
        let viewMenu = app.menuBars.menuBarItems["View"]
        guard viewMenu.waitForExistence(timeout: 2) else { return false }
        viewMenu.click()
        return true
    }
}
