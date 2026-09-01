import XCTest

/// End-to-end coverage for the FLASH controls layered over a real terminal
/// surface. The test intentionally observes only public accessibility state:
/// the down control is both the user-facing signal that the viewport is away
/// from the bottom and the proof that a pin restored an earlier viewport.
final class GhosttySurfaceNavigationUITests: GhosttyCustomConfigCase {
    override func setUpWithError() throws {
        try super.setUpWithError()

        try updateConfig(
            """
            title = "GhosttySurfaceNavigationUITests"
            working-directory = /private/tmp
            command = /bin/zsh -c "/usr/bin/jot 600; exec /bin/zsh -l"
            keybind = ctrl+shift+u=scroll_page_up
            """
        )
    }

    @MainActor
    func testScrollToBottomAndPinRestoreSavedViewport() throws {
        let app = try ghosttyApplication(
            defaultsSuite: "\(Self.defaultsSuiteName).Navigation.\(UUID().uuidString)"
        )
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(
            terminal.waitForExistence(timeout: 5),
            "A terminal surface must exist before generating scrollback"
        )

        let addPin = navigationElement(
            prefixedBy: "terminal-surface.add-pin.",
            in: app
        )
        terminal.typeKey("u", modifierFlags: [.control, .shift])

        let scrollToBottom = navigationElement(
            prefixedBy: "terminal-surface.scroll-to-bottom.",
            in: app
        )
        XCTAssertTrue(
            scrollToBottom.waitForExistence(timeout: 5),
            "Leaving the bottom of scrollback must expose the down control"
        )
        XCTAssertTrue(
            waitUntilEnabled(addPin, timeout: 5),
            "A viewport inside scrollback history must be pinnable"
        )

        addPin.click()

        let firstPin = navigationElement(
            prefixedBy: "terminal-surface.pin.",
            suffixedBy: ".1",
            in: app
        )
        XCTAssertTrue(
            firstPin.waitForExistence(timeout: 5),
            "Adding a pin must expose the numbered Pin 1 control"
        )
        XCTAssertEqual(firstPin.label, "Pin 1")

        scrollToBottom.click()
        XCTAssertTrue(
            scrollToBottom.waitForNonExistence(timeout: 5),
            "The down control must disappear after returning to newest output"
        )

        firstPin.click()
        XCTAssertTrue(
            scrollToBottom.waitForExistence(timeout: 5),
            "Clicking Pin 1 must restore its saved non-bottom viewport"
        )

        scrollToBottom.click()
        XCTAssertTrue(
            scrollToBottom.waitForNonExistence(timeout: 5),
            "The restored viewport must still be able to return to the bottom"
        )

        firstPin.rightClick()
        let removePin = app.menuItems["Remove Pin 1"]
        XCTAssertTrue(
            removePin.waitForExistence(timeout: 2),
            "Right-clicking a numbered pin must expose its removal action"
        )
        removePin.click()
        XCTAssertTrue(
            firstPin.waitForNonExistence(timeout: 5),
            "Removing Pin 1 must clear its numbered control"
        )
    }

    @MainActor
    func testSplitSurfacesKeepIndependentBottomStateAcrossSidebarToggle() throws {
        let app = try ghosttyApplication(
            defaultsSuite: "\(Self.defaultsSuiteName).NavigationSplits.\(UUID().uuidString)"
        )
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.typeKey("d", modifierFlags: .command)

        let leftPane = app.groups["Left pane"]
        let rightPane = app.groups["Right pane"]
        XCTAssertTrue(leftPane.waitForExistence(timeout: 5))
        XCTAssertTrue(rightPane.waitForExistence(timeout: 5))

        rightPane.click()
        rightPane.typeKey("u", modifierFlags: [.control, .shift])
        XCTAssertTrue(
            waitForNavigationElementCount(
                prefixedBy: "terminal-surface.scroll-to-bottom.",
                count: 1,
                in: app
            )
        )

        leftPane.click()
        leftPane.typeKey("u", modifierFlags: [.control, .shift])
        XCTAssertTrue(
            waitForNavigationElementCount(
                prefixedBy: "terminal-surface.scroll-to-bottom.",
                count: 2,
                in: app
            ),
            "Each split must expose its own non-bottom control"
        )
        let originalIdentifiers = Set(
            navigationElements(
                prefixedBy: "terminal-surface.scroll-to-bottom.",
                in: app
            ).allElementsBoundByIndex.map(\.identifier)
        )
        XCTAssertEqual(originalIdentifiers.count, 2)

        let fileBrowserToggle = app.buttons["terminal-file-sidebar.toggle"]
        XCTAssertTrue(fileBrowserToggle.waitForExistence(timeout: 5))
        fileBrowserToggle.click()
        XCTAssertTrue(
            app.groups["terminal-file-sidebar"].waitForNonExistence(timeout: 5)
        )
        fileBrowserToggle.click()
        XCTAssertTrue(
            app.groups["terminal-file-sidebar"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            waitForNavigationElementCount(
                prefixedBy: "terminal-surface.scroll-to-bottom.",
                count: 2,
                in: app
            )
        )
        XCTAssertEqual(
            Set(
                navigationElements(
                    prefixedBy: "terminal-surface.scroll-to-bottom.",
                    in: app
                ).allElementsBoundByIndex.map(\.identifier)
            ),
            originalIdentifiers,
            "Sidebar reconstruction must retain each split's navigation model"
        )

        let orderedIdentifiers = originalIdentifiers.sorted()
        app.descendants(matching: .any)[orderedIdentifiers[0]].click()
        XCTAssertTrue(
            waitForNavigationElementCount(
                prefixedBy: "terminal-surface.scroll-to-bottom.",
                count: 1,
                in: app
            )
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[orderedIdentifiers[1]].exists,
            "Returning one split to bottom must not change the other split"
        )

        app.descendants(matching: .any)[orderedIdentifiers[1]].click()
        XCTAssertTrue(
            waitForNavigationElementCount(
                prefixedBy: "terminal-surface.scroll-to-bottom.",
                count: 0,
                in: app
            )
        )
    }

    @MainActor
    private func navigationElement(
        prefixedBy prefix: String,
        suffixedBy suffix: String? = nil,
        in app: XCUIApplication
    ) -> XCUIElement {
        let predicate: NSPredicate
        if let suffix {
            predicate = NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                prefix,
                suffix
            )
        } else {
            predicate = NSPredicate(
                format: "identifier BEGINSWITH %@",
                prefix
            )
        }

        return app.descendants(matching: .any)
            .matching(predicate)
            .firstMatch
    }

    @MainActor
    private func navigationElements(
        prefixedBy prefix: String,
        in app: XCUIApplication
    ) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        )
    }

    @MainActor
    private func waitForNavigationElementCount(
        prefixedBy prefix: String,
        count: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> Bool {
        let query = navigationElements(prefixedBy: prefix, in: app)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in query.count == count },
            object: query
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }
}
