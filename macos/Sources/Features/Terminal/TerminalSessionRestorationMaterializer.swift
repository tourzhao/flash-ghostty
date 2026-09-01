import AppKit

/// Converts an accepted passive archive into live terminal windows. Keeping
/// this out of the AppKit restoration adapter makes the PTY-starting boundary
/// explicit and reviewable.
@MainActor
enum TerminalSessionRestorationMaterializer {
    static func materialize(
        snapshot: TerminalRestorableSnapshot<TerminalRestorableState>,
        appDelegate: AppDelegate,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        guard let state = snapshot.decodedValue() else {
            completionHandler(nil, TerminalRestoreError.stateDecodeFailed)
            return
        }

        // Window creation has to go through TerminalController so libghostty
        // can route events to the restored surfaces.
        let controller = TerminalController(
            appDelegate.ghostty,
            withSurfaceTree: state.surfaceTree
        )

        // Apply workspace-owned presentation state before the SwiftUI root is
        // created. This avoids briefly constructing and sizing a file browser
        // that the accepted archive says should be hidden.
        controller.restoreSessionSidebarVisibility(state.sessionSidebarIsVisible)
        controller.restoreFileBrowserVisibility(state.fileBrowserIsVisible)
        controller.restoreFileBrowserSelectedFileTypes(
            state.fileBrowserSelectedFileTypes
        )
        let focusedView = restoredFocusedView(
            identifier: state.focusedSurface,
            in: controller.surfaceTree
        )
        if let focusedView {
            // Bind the restored directory and metadata before the SwiftUI root
            // reads them. The responder itself is restored only after the view
            // has been attached to the returned window below.
            controller.focusedSurface = focusedView
        }
        // Assign the title last. BaseTerminalController deliberately defers
        // applying a pre-load title until windowDidLoad, but keeping layout
        // state first also makes this ordering resilient to future title code.
        applyTitle(state.titleOverride, to: controller)

        guard let window = controller.window else {
            completionHandler(nil, TerminalRestoreError.windowDidNotLoad)
            return
        }

        // Restore presentation metadata without causing unnecessary archive
        // invalidations while AppKit is still assembling the window group.
        if let tabColor = state.tabColor {
            (window as? TerminalWindow)?.tabColor = tabColor
        }

        if let focusedView {
            restoreFocus(to: focusedView, inWindow: window)
        }

        completionHandler(window, nil)
        guard let mode = state.effectiveFullscreenMode, mode != .native else {
            // Native fullscreen is restored by AppKit itself.
            return
        }

        // Give the window to AppKit first, then adjust its frame and style to
        // minimize visible frame changes.
        controller.toggleFullscreen(mode: mode)
    }

    /// Applies archived controller-owned state without forcing NSWindowController
    /// to load its window. Kept separate from live surface materialization so
    /// the archive-to-controller handoff can be regression tested safely.
    static func applyTitle(
        _ titleOverride: String?,
        to controller: BaseTerminalController
    ) {
        controller.titleOverride = titleOverride
    }

    /// Resolves archived focus without leaving a restored split session with
    /// no metadata source. Older, interrupted, or partially-written archives
    /// may omit the identifier or point at a surface that no longer exists.
    /// Split-tree traversal order is stable, so the first visible surface is
    /// a deterministic fallback for both terminal focus and working-directory
    /// restoration. A zoomed subtree takes precedence because it is the only
    /// subtree rendered while the terminal is zoomed.
    static func restoredFocusedView<ViewType>(
        identifier: String?,
        in tree: SplitTree<ViewType>
    ) -> ViewType? where ViewType.ID == UUID {
        if let identifier,
           let identifier = UUID(uuidString: identifier),
           let exactMatch = tree.first(where: { $0.id == identifier }) {
            return exactMatch
        }

        return tree.zoomed?.leftmostLeaf() ?? tree.root?.leftmostLeaf()
    }

    /// A restored SurfaceView is attached asynchronously by SwiftUI. Retry for
    /// up to two seconds before giving up on focus restoration.
    private static func restoreFocus(
        to surface: Ghostty.SurfaceView,
        inWindow window: NSWindow,
        attempts: Int = 0
    ) {
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            guard let viewWindow = surface.window else {
                restoreFocus(
                    to: surface,
                    inWindow: window,
                    attempts: attempts + 1
                )
                return
            }

            guard viewWindow == window else { return }
            window.makeFirstResponder(surface)
            // AppKit owns restored-window ordering and native-tab selection.
            // Ordering an individual member here can detach it while the
            // restored group is still converging.
        }
    }
}
