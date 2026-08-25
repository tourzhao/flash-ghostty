import AppKit

@MainActor
protocol SessionRestorationPromptPresenting: AnyObject {
    func present(
        completion: @escaping (SessionRestorationDecision) -> Void
    )
}

/// Presents the startup choice as a sheet when a host window exists. During
/// state restoration AppKit has not created that host yet, so the standalone
/// alert is app-modal until the user makes the launch-wide decision.
@MainActor
final class AppKitSessionRestorationPromptPresenter: NSObject,
                                                        SessionRestorationPromptPresenting {
    private var activeAlert: NSAlert?
    private var completion: ((SessionRestorationDecision) -> Void)?

    func present(
        completion: @escaping (SessionRestorationDecision) -> Void
    ) {
        guard self.completion == nil else { return }

        // CLI launches have not reached their normal activation setup yet.
        // Temporarily ensure the confirmation is visible; didFinishLaunching
        // will reapply any configured hidden-app policy afterwards.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)

        let alert = NSAlert()
        alert.messageText = "Restore Previous Sessions?"
        alert.informativeText = """
        \(FlashGhosttyProductProfile.displayName) can restore windows, tabs, session names, working directories, and layouts from the last time you quit.
        Running commands, terminal output, and Codex or Claude Code processes cannot be resumed.
        """
        alert.alertStyle = .informational

        let restoreButton = alert.addButton(withTitle: "Restore Sessions")
        restoreButton.identifier = .init("session-restoration-prompt.restore")
        let freshButton = alert.addButton(withTitle: "Start Fresh")
        freshButton.identifier = .init("session-restoration-prompt.start-fresh")
        freshButton.keyEquivalent = "\u{1b}"

        // This panel is a decision surface, never part of the user's terminal
        // workspace. In particular, it must not enter AppKit's saved window
        // graph while the previous archive is being held behind the prompt.
        alert.window.isRestorable = false
        alert.window.identifier = .init("session-restoration-prompt")

        self.activeAlert = alert
        self.completion = completion

        if let parent = sheetParent(for: alert) {
            alert.beginSheetModal(for: parent) { [weak self] response in
                let decision: SessionRestorationDecision =
                    response == .alertFirstButtonReturn ? .restore : .startFresh
                self?.finish(with: decision)
            }
            return
        }

        // AppKit waits for the restoration completion handler before it
        // finishes activating the application. A modeless alert can therefore
        // remain on the previous Space indefinitely. Running this one decision
        // app-modally completes that handshake without decoding or starting
        // any restored terminal session first.
        alert.window.collectionBehavior.insert(.moveToActiveSpace)
        alert.window.collectionBehavior.insert(.fullScreenAuxiliary)
        alert.window.hidesOnDeactivate = false
        alert.window.level = .modalPanel
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let decision: SessionRestorationDecision =
            response == .alertFirstButtonReturn ? .restore : .startFresh
        finish(with: decision)
    }

    private func sheetParent(for alert: NSAlert) -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow]
        return candidates.compactMap { $0 }.first {
            $0 !== alert.window && $0.isVisible && $0.attachedSheet == nil
        }
    }

    private func finish(with decision: SessionRestorationDecision) {
        guard let completion else { return }

        self.completion = nil
        activeAlert?.window.orderOut(nil)
        activeAlert = nil
        completion(decision)
    }
}
