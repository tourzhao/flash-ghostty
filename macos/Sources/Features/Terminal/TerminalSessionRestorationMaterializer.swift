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
        guard let window = controller.window else {
            completionHandler(nil, TerminalRestoreError.windowDidNotLoad)
            return
        }

        // Restore presentation metadata without causing unnecessary archive
        // invalidations while AppKit is still assembling the window group.
        if let tabColor = state.tabColor {
            (window as? TerminalWindow)?.tabColor = tabColor
        }
        controller.titleOverride = state.titleOverride
        controller.restoreSessionSidebarVisibility(state.sessionSidebarIsVisible)

        if let focusedIdentifier = state.focusedSurface,
           let focusedView = controller.surfaceTree.first(where: {
               $0.id.uuidString == focusedIdentifier
           }) {
            controller.focusedSurface = focusedView
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
