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

        XCTAssertTrue(
            element("terminal-file-sidebar.list", in: app)
                .waitForExistence(timeout: 5)
        )
        let row = app.buttons["initial.swift"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
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
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }
}
