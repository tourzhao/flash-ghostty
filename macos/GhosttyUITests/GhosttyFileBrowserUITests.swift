import AppKit
import XCTest

final class GhosttyFileBrowserUITests: GhosttyCustomConfigCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FLASH-Ghostty-FileBrowser-UI-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        try Data("initial".utf8).write(
            to: workingDirectory.appendingPathComponent("initial.swift")
        )
        try updateConfig(
            """
            title = "GhosttyFileBrowserUITests"
            command = /bin/zsh
            working-directory = \(workingDirectory.path)
            """
        )
    }

    override func tearDown() async throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        try await super.tearDown()
    }

    /// Exercises the real SwiftUI Table, metadata-to-CWD binding, vnode
    /// monitor, and filesystem enumeration rather than a synthetic NSTableView.
    @MainActor
    func testListAppearsAndRefreshesAfterExternalCreation() throws {
        let app = try ghosttyApplication(
            defaultsSuite: "\(Self.defaultsSuiteName).FileBrowser.\(UUID().uuidString)"
        )
        app.launch()

        XCTAssertTrue(
            element("terminal-file-sidebar", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("terminal-file-sidebar.list", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["initial.swift"].waitForExistence(timeout: 5)
        )

        try Data("external".utf8).write(
            to: workingDirectory.appendingPathComponent("external.md")
        )
        XCTAssertTrue(
            app.buttons["external.md"].waitForExistence(timeout: 5),
            "The live file browser must refresh without a manual reload"
        )
    }

    /// Verifies the real Table focus bridge and the public macOS file-URL
    /// pasteboard format used when another app receives Command-V.
    @MainActor
    func testCommandCCopiesSelectedFileToSystemPasteboard() throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        let app = try ghosttyApplication(
            defaultsSuite: "\(Self.defaultsSuiteName).FileBrowserCopy.\(UUID().uuidString)"
        )
        app.launch()

        let table = element("terminal-file-sidebar.list", in: app)
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["initial.swift"].waitForExistence(timeout: 5))

        // The filename is an accessibility button for the row's primary Open
        // action. Select through the native outline row so this exercises the
        // Table selection contract instead of activating that nested button.
        let nativeRow = table.outlineRows.firstMatch
        XCTAssertTrue(nativeRow.waitForExistence(timeout: 5))
        nativeRow.click()

        let copyButton = app.buttons["terminal-file-sidebar.copy"]
        let selectionPublished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                copyButton.exists && copyButton.isEnabled &&
                    app.staticTexts["1 of 1 selected"].exists
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selectionPublished], timeout: 5),
            .completed,
            "The real Table selection must reach the command bridge before Command-C"
        )
        app.typeKey("c", modifierFlags: .command)

        let expectedURL = workingDirectory
            .appendingPathComponent("initial.swift")
            .standardizedFileURL
        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let urls = pasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [URL]
                return urls?.map(\.standardizedFileURL) == [expectedURL]
            },
            object: pasteboard
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [copied], timeout: 5),
            .completed,
            "Command-C in the file list must publish a Finder-compatible file URL"
        )
    }

    /// Each native tab retains its terminal root, but only the selected root
    /// mounts the live Finder-style sidebar. Verify a freshly selected root
    /// recreates the list and its rows after every direction of tab switching.
    @MainActor
    func testFileRowsRemountAfterNativeTabSelection() throws {
        let app = try ghosttyApplication(
            defaultsSuite: "\(Self.defaultsSuiteName).FileBrowserTabs.\(UUID().uuidString)"
        )
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForInitialFileRow(in: app))

        terminal.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForSelectedSession(at: 1, count: 2, in: app))
        XCTAssertTrue(
            waitForInitialFileRow(in: app),
            "A newly selected native-tab root must mount the complete file sidebar"
        )

        for index in [0, 1, 0] {
            app.typeKey("\(index + 1)", modifierFlags: .command)
            XCTAssertTrue(
                waitForSelectedSession(at: index, count: 2, in: app),
                "Session \(index + 1) must become the selected native-tab root"
            )
            XCTAssertTrue(
                waitForInitialFileRow(in: app),
                "Selecting session \(index + 1) must remount the file sidebar rows"
            )
        }
    }

    /// Uses a real OSC 8 file link and the exact item built by the native
    /// file-action menu. A DEBUG-only seam dispatches that item because some CI
    /// macOS versions omit programmatic popup menus from XCUITest's AX tree.
    /// The revalidation barrier proves the second split receives focus before
    /// the originating split's reveal request returns to the main actor.
    @MainActor
    func testRevealKeepsOriginatingSplitAfterFocusChangesDuringRevalidation() throws {
        let originDirectory = workingDirectory.appendingPathComponent(
            "origin",
            isDirectory: true
        )
        let focusedDirectory = workingDirectory.appendingPathComponent(
            "focused",
            isDirectory: true
        )
        let barrierDirectory = workingDirectory.appendingPathComponent(
            ".terminal-file-revalidation-barrier",
            isDirectory: true
        )
        for directory in [originDirectory, focusedDirectory, barrierDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let targetName = "reveal-target.txt"
        let focusedName = "focused-split-only.txt"
        let targetURL = originDirectory.appendingPathComponent(targetName)
        try Data("origin".utf8).write(to: targetURL)
        try Data("focused".utf8).write(
            to: focusedDirectory.appendingPathComponent(focusedName)
        )

        let resumeURL = barrierDirectory.appendingPathComponent("resume")
        defer {
            _ = FileManager.default.createFile(
                atPath: resumeURL.path,
                contents: Data()
            )
        }

        let app = try ghosttyApplication(
            defaultsSuite:
                "\(Self.defaultsSuiteName).FileBrowserSplitReveal.\(UUID().uuidString)"
        )
        app.launchEnvironment[
            "GHOSTTY_TEST_TERMINAL_FILE_REVALIDATION_BARRIER"
        ] = barrierDirectory.path
        app.launchEnvironment[
            "GHOSTTY_TEST_TERMINAL_FILE_AUTO_REVEAL"
        ] = "1"
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.typeKey("d", modifierFlags: .command)

        let leftPane = app.groups["Left pane"]
        let rightPane = app.groups["Right pane"]
        XCTAssertTrue(leftPane.waitForExistence(timeout: 5))
        XCTAssertTrue(rightPane.waitForExistence(timeout: 5))

        try moveShell(
            to: originDirectory,
            expectedFile: targetName,
            in: leftPane,
            app: app
        )
        try moveShell(
            to: focusedDirectory,
            expectedFile: focusedName,
            in: rightPane,
            app: app
        )

        leftPane.click()
        XCTAssertTrue(waitForFileRow(targetName, in: app))
        XCTAssertTrue(
            app.buttons[focusedName].waitForNonExistence(timeout: 10),
            "The sidebar must finish switching back to the originating split"
        )
        let leftSurface = leftPane.textViews.firstMatch
        XCTAssertTrue(leftSurface.waitForExistence(timeout: 5))
        XCTAssertTrue(leftSurface.isHittable)

        // Keep the OSC 8 target fixed while its visible label fills far more
        // cells than the largest CI terminal viewport. The center is therefore
        // a deterministic hyperlink hit point regardless of font metrics.
        pasteText(
            "clear; printf '\\033]8;;%s\\033\\\\' " +
                "\(shellQuoted(targetURL.absoluteString)); " +
                "printf 'X%.0s' {1..5000}; " +
                "printf '\\033]8;;\\033\\\\\\nFLASH_%s\\n' 'LINKS_READY'",
            into: leftSurface
        )
        leftSurface.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForTerminalText("FLASH_LINKS_READY", in: leftSurface),
            "The originating split must finish rendering the OSC 8 file link"
        )

        let linkPoint = leftSurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )

        // `leftPane.click()` focused this exact center before the OSC 8 link
        // existed. Move across terminal cells first so the command-modified
        // hover must refresh Ghostty's cached hyperlink hit test.
        leftSurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)
        ).hover()
        XCUIElement.perform(withKeyModifiers: .command) {
            linkPoint.hover()
            linkPoint.click()
        }

        let enteredURL = barrierDirectory.appendingPathComponent("entered")
        XCTAssertTrue(
            waitForFile(at: enteredURL, timeout: 10),
            "The OSC 8 menu action must reach background filesystem revalidation"
        )

        rightPane.click()
        XCTAssertTrue(
            waitForWorkingDirectory(focusedDirectory.path, in: app),
            "The second split must own focus before revalidation resumes"
        )
        XCTAssertTrue(
            waitForFileRow(focusedName, in: app),
            "The sidebar must first follow the newly-focused split"
        )

        _ = FileManager.default.createFile(
            atPath: resumeURL.path,
            contents: Data()
        )

        XCTAssertTrue(
            waitForRevealedSelection(
                targetName: targetName,
                displacedName: focusedName,
                in: app
            ),
            "The completed reveal must select the originating split's target"
        )
        XCTAssertTrue(
            waitForWorkingDirectory(focusedDirectory.path, in: app),
            "Completing the reveal must not steal terminal focus from the second split"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: barrierDirectory
                    .appendingPathComponent("timed-out").path
            ),
            "The UI-test barrier must be resumed explicitly, not time out"
        )
    }

    @MainActor
    private func waitForSelectedSession(
        at index: Int,
        count expectedCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            let selectors = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                    "terminal-session-sidebar.row.",
                    ".select"
                )
            )
            guard selectors.count == expectedCount else { return false }
            return (selectors.element(boundBy: index).value as? String)?
                .contains("Selected") == true
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForInitialFileRow(
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            self.element("terminal-file-sidebar.list", in: app).exists &&
                app.buttons["initial.swift"].exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func moveShell(
        to directory: URL,
        expectedFile: String,
        in pane: XCUIElement,
        app: XCUIApplication
    ) throws {
        pane.click()
        pasteText(
            "cd \(shellQuoted(directory.path)) && " +
                "printf '\\033]7;file://localhost%s\\007' \"$PWD\"",
            into: pane
        )
        pane.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForWorkingDirectory(directory.path, in: app),
            "The terminal did not publish \(directory.path)"
        )
        XCTAssertTrue(
            waitForFileRow(expectedFile, in: app),
            "The file browser did not load \(expectedFile)"
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
    private func waitForFileRow(
        _ name: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        app.buttons[name].waitForExistence(timeout: timeout)
    }

    @MainActor
    private func waitForTerminalText(
        _ text: String,
        in surface: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            (surface.value as? String)?.contains(text) == true
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: surface
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForFile(
        at url: URL,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: url.path)
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: self
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForRevealedSelection(
        targetName: String,
        displacedName: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        let target = app.buttons[targetName]
        let displaced = app.buttons[displacedName]
        let copyButton = element("terminal-file-sidebar.copy", in: app)
        let predicate = NSPredicate { _, _ in
            target.exists &&
                !displaced.exists &&
                copyButton.isEnabled &&
                app.staticTexts["1 of 1 selected"].exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

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

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
}
