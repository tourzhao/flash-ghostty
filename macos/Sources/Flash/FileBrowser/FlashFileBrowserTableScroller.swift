import AppKit
import SwiftUI

/// A narrow bridge for the one capability SwiftUI's macOS `Table` does not
/// expose: programmatically scrolling a selected row into view.
///
/// The hierarchy lookup runs only for a new reveal UUID, so ordinary terminal
/// and file-list scrolling never pays for AppKit introspection.
struct FlashFileBrowserTableScroller: NSViewRepresentable {
    let presentation: FlashFileBrowserRevealPresentation?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let presentation else {
            context.coordinator.cancel()
            return
        }
        context.coordinator.scroll(presentation, from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        private static let retryDelays: [TimeInterval] = [0, 0.016, 0.05, 0.1, 0.2]

        private var completedRequestID: UUID?
        private var pendingRequestID: UUID?
        private var retryWorkItem: DispatchWorkItem?

        func scroll(
            _ presentation: FlashFileBrowserRevealPresentation,
            from probe: NSView
        ) {
            guard completedRequestID != presentation.requestID,
                  pendingRequestID != presentation.requestID else { return }

            retryWorkItem?.cancel()
            pendingRequestID = presentation.requestID
            attempt(presentation, from: probe, attemptIndex: 0)
        }

        func cancel() {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            pendingRequestID = nil
        }

        private func attempt(
            _ presentation: FlashFileBrowserRevealPresentation,
            from probe: NSView,
            attemptIndex: Int
        ) {
            let workItem = DispatchWorkItem { [weak self, weak probe] in
                guard let self,
                      let probe,
                      self.pendingRequestID == presentation.requestID else { return }

                if let tableView = self.nearestTableView(to: probe),
                   presentation.rowIndex >= 0,
                   presentation.rowIndex < tableView.numberOfRows {
                    tableView.scrollRowToVisible(presentation.rowIndex)
                    self.completedRequestID = presentation.requestID
                    self.pendingRequestID = nil
                    self.retryWorkItem = nil
                    return
                }

                let nextAttemptIndex = attemptIndex + 1
                guard Self.retryDelays.indices.contains(nextAttemptIndex) else {
                    self.pendingRequestID = nil
                    self.retryWorkItem = nil
                    return
                }
                self.attempt(
                    presentation,
                    from: probe,
                    attemptIndex: nextAttemptIndex
                )
            }
            retryWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.retryDelays[attemptIndex],
                execute: workItem
            )
        }

        private func nearestTableView(to probe: NSView) -> NSTableView? {
            let probeFrame = probe.convert(probe.bounds, to: nil)
            var ancestor = probe.superview

            while let candidate = ancestor {
                let tables = descendantTableViews(in: candidate)
                    .filter { $0.window === probe.window && !$0.isHidden }
                if let nearest = tables.max(by: { lhs, rhs in
                    overlapArea(lhs, with: probeFrame) < overlapArea(rhs, with: probeFrame)
                }), overlapArea(nearest, with: probeFrame) > 0 {
                    return nearest
                }
                ancestor = candidate.superview
            }

            return nil
        }

        private func descendantTableViews(in view: NSView) -> [NSTableView] {
            var result: [NSTableView] = []
            for subview in view.subviews {
                if let tableView = subview as? NSTableView {
                    result.append(tableView)
                } else {
                    result.append(contentsOf: descendantTableViews(in: subview))
                }
            }
            return result
        }

        private func overlapArea(_ tableView: NSTableView, with frame: NSRect) -> CGFloat {
            let intersection = tableView.convert(tableView.bounds, to: nil).intersection(frame)
            guard !intersection.isNull else { return 0 }
            return intersection.width * intersection.height
        }
    }
}
