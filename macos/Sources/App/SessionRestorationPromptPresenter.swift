import AppKit

@MainActor
protocol SessionRestorationPromptPresenting: AnyObject {
    func present(
        completion: @escaping (SessionRestorationDecision) -> Void
    )
}

/// Presents the startup choice as a sheet when a host window exists. During
/// state restoration AppKit has not created that host yet, so the standalone
/// decision uses a retained panel until the user makes the launch-wide choice.
@MainActor
final class AppKitSessionRestorationPromptPresenter: NSObject,
                                                        SessionRestorationPromptPresenting {
    private var activeAlert: NSAlert?
    private var activePanel: NSPanel?
    private var activePanelController: NSWindowController?
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

        // AppKit disables the application while asynchronous restoration
        // completion handlers are outstanding. Merely ordering a modeless
        // window in that interval leaves no visible or accessible decision UI.
        // A retained custom panel plus a nested modal session keeps the choice
        // interactive while continuing to service the normal event loop.
        activeAlert = nil
        let panel = makeStandalonePanel()
        let panelController = NSWindowController(window: panel)
        activePanel = panel
        activePanelController = panelController
        panel.center()
        panelController.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
    }

    @objc private func restoreFromStandaloneAlert(_ sender: Any?) {
        finish(with: .restore)
    }

    @objc private func startFreshFromStandaloneAlert(_ sender: Any?) {
        finish(with: .startFresh)
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
        if NSApp.modalWindow === activePanel {
            NSApp.stopModal()
        }
        activeAlert?.window.orderOut(nil)
        activeAlert = nil
        activePanel?.close()
        activePanel = nil
        activePanelController = nil
        completion(decision)
    }

    private func makeStandalonePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 190),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = FlashGhosttyProductProfile.displayName
        panel.identifier = .init("session-restoration-prompt")
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .modalPanel
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = NSTextField(labelWithString: "Restore Previous Sessions?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: """
        \(FlashGhosttyProductProfile.displayName) can restore windows, tabs, session names, working directories, and layouts from the last time you quit.
        Running commands, terminal output, and Codex or Claude Code processes cannot be resumed.
        """)
        detail.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 8

        let message = NSStackView(views: [icon, labels])
        message.orientation = .horizontal
        message.alignment = .top
        message.spacing = 16

        let freshButton = NSButton(
            title: "Start Fresh",
            target: self,
            action: #selector(startFreshFromStandaloneAlert(_:))
        )
        freshButton.identifier = .init("session-restoration-prompt.start-fresh")
        freshButton.keyEquivalent = "\u{1b}"

        let restoreButton = NSButton(
            title: "Restore Sessions",
            target: self,
            action: #selector(restoreFromStandaloneAlert(_:))
        )
        restoreButton.identifier = .init("session-restoration-prompt.restore")
        restoreButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [freshButton, restoreButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, buttons])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY

        let content = NSStackView(views: [message, buttonRow])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        panel.contentView = NSView()
        panel.contentView?.addSubview(content)
        if let contentView = panel.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
                content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
                content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
                content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
                message.widthAnchor.constraint(equalTo: content.widthAnchor),
                buttonRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        }
        return panel
    }
}
