import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite @MainActor
struct FlashFileBrowserTableScrollerTests {
    @Test
    func scrollsMatchingTableOncePerRequestID() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root

        let scrollView = NSScrollView(
            frame: NSRect(x: 20, y: 20, width: 280, height: 200)
        )
        let tableView = RecordingTableView(
            frame: NSRect(x: 0, y: 0, width: 280, height: 400)
        )
        let dataSource = FixedRowCountDataSource(rowCount: 12)
        tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
        tableView.dataSource = dataSource
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        // A SwiftUI background representable is a sibling of the native table
        // hierarchy and occupies the same window-space rectangle.
        let probe = NSView(frame: scrollView.frame)
        root.addSubview(probe)
        tableView.reloadData()

        let coordinator = FlashFileBrowserTableScroller.Coordinator()
        let first = presentation(requestID: UUID(), rowIndex: 8)
        coordinator.scroll(first, from: probe)

        #expect(await waitUntil { tableView.scrolledRows == [8] })

        coordinator.scroll(first, from: probe)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(tableView.scrolledRows == [8])

        coordinator.scroll(
            presentation(requestID: UUID(), rowIndex: 3),
            from: probe
        )
        #expect(await waitUntil { tableView.scrolledRows == [8, 3] })
        coordinator.cancel()
    }

    @Test
    func cancellationPreventsPendingRetryFromScrollingReplacementList() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root
        let probe = NSView(frame: root.bounds)
        root.addSubview(probe)

        let coordinator = FlashFileBrowserTableScroller.Coordinator()
        coordinator.scroll(
            presentation(requestID: UUID(), rowIndex: 2),
            from: probe
        )
        coordinator.cancel()

        let tableView = RecordingTableView(frame: root.bounds)
        let dataSource = FixedRowCountDataSource(rowCount: 5)
        tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
        tableView.dataSource = dataSource
        tableView.reloadData()
        root.addSubview(tableView)

        try? await Task.sleep(nanoseconds: 450_000_000)
        #expect(tableView.scrolledRows.isEmpty)
    }

    private func presentation(
        requestID: UUID,
        rowIndex: Int
    ) -> FlashFileBrowserRevealPresentation {
        .init(
            requestID: requestID,
            directoryPath: "/tmp",
            targetItemID: "target-\(rowIndex)",
            selectedItemIDs: ["target-\(rowIndex)"],
            rowIndex: rowIndex
        )
    }

    private func waitUntil(
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

@MainActor
private final class RecordingTableView: NSTableView {
    private(set) var scrolledRows: [Int] = []

    override func scrollRowToVisible(_ row: Int) {
        scrolledRows.append(row)
    }
}

@MainActor
private final class FixedRowCountDataSource: NSObject, NSTableViewDataSource {
    let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }
}
