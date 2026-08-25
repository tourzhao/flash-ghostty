import AppKit

/// Owns the AppKit window-chrome behavior that is specific to FLASH's session
/// sidebar presentation.
///
/// `TerminalWindow` remains the `NSWindow` integration point because AppKit
/// requires overrides there. Those overrides delegate policy and mutations to
/// this object so the upstream window implementation does not also become the
/// sidebar implementation.
@MainActor
final class FlashSidebarWindowChromeCoordinator: NSObject {
    private weak var window: TerminalWindow?

    private var sidebarAccessory: NSTitlebarAccessoryViewController?
    private var sidebarToggleButton: NSButton?

    /// Coalesces title/font changes while AppKit and SwiftUI finish installing
    /// the selected native tab's titlebar and content root.
    private var titleLayoutGeneration: UInt = 0

    init(window: TerminalWindow) {
        self.window = window
        super.init()
    }

    var usesSidebarPresentation: Bool {
        guard let window else { return false }
        let selectedWindow = window.tabGroup?.selectedWindow as? TerminalWindow
        return (selectedWindow ?? window).terminalController?
            .usesSessionSidebarTitlebar == true
    }

    func installToggleAccessoryIfNeeded() {
        guard sidebarAccessory == nil, let window else { return }

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.identifier = NSUserInterfaceItemIdentifier("terminal-session-sidebar.toggle")
        button.setAccessibilityIdentifier("terminal-session-sidebar.toggle")
        button.setAccessibilityRole(.button)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(toggleSidebar(_:))

        let image = NSImage(
            systemSymbolName: "sidebar.leading",
            accessibilityDescription: nil
        ) ?? NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: nil
        )
        button.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        ) ?? image

        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = NSUserInterfaceItemIdentifier(
            "terminal-session-sidebar.toggle.accessory"
        )
        // NSTitlebarAccessoryViewController only accepts left, right, or
        // bottom here. In a left-to-right titlebar, left is the leading slot
        // between the traffic lights and the proxy icon/title.
        accessory.layoutAttribute = .left
        accessory.view = button

        sidebarAccessory = accessory
        sidebarToggleButton = button
        window.addTitlebarAccessoryViewController(accessory)
        updateToggleAccessibility()
        visibilityDidChange()

        // The nib can finish connecting its window controller after the window
        // awakens. Refresh once more so restoration starts from controller state.
        DispatchQueue.main.async { [weak self] in
            self?.updateToggleAccessibility()
            self?.visibilityDidChange()
        }
    }

    func windowDidBecomeMain() {
        updateToggleAccessibility()
        DispatchQueue.main.async { [weak self] in
            self?.updateToggleAccessibility()
        }
        visibilityDidChange()
    }

    func windowDidResignMain() {
        updateToggleAccessibility()
        DispatchQueue.main.async { [weak self] in
            self?.updateToggleAccessibility()
        }
    }

    func visibilityDidChange() {
        guard let window else { return }
        updateToggleAccessibility(in: window.tabGroup)
        guard let button = sidebarToggleButton else { return }

        let isVisible = window.terminalController?.sessionSidebarIsVisible ?? true
        let actionTitle = isVisible ? "Hide Sidebar" : "Show Sidebar"

        button.toolTip = "\(actionTitle) (⌃⌘S)"
        button.setAccessibilityLabel(actionTitle)
        button.setAccessibilityValue(isVisible ? "Shown" : "Hidden")
        button.setAccessibilityHelp(
            isVisible
                ? "Hides the session sidebar and gives the terminal more space."
                : "Shows the session sidebar."
        )
    }

    /// Updates accessibility using the group captured by the controller's
    /// selection observation. This avoids a transient `window.tabGroup` while
    /// AppKit moves native-tab accessories.
    func tabSelectionDidChange(in tabGroup: NSWindowTabGroup?) {
        updateToggleAccessibility(in: tabGroup)
    }

    /// Native tabs are independent windows, so each owns a copy of the toggle.
    /// Only the selected window's visible copy belongs in the accessibility tree.
    private func updateToggleAccessibility(
        in capturedTabGroup: NSWindowTabGroup? = nil
    ) {
        guard let window, let button = sidebarToggleButton else { return }

        let tabGroup = capturedTabGroup ?? window.tabGroup
        guard let tabGroup,
              tabGroup.windows.count > 1,
              tabGroup.windows.contains(where: { $0 === window }) else {
            button.setAccessibilityElement(true)
            return
        }

        // Keep the previous value while AppKit is briefly between selections.
        guard let selectedWindow = tabGroup.selectedWindow else { return }
        button.setAccessibilityElement(selectedWindow === window)
    }

    @objc private func toggleSidebar(_ sender: NSButton) {
        window?.terminalController?.toggleSessionSidebar(sender)
        visibilityDidChange()
    }

    func canMergeAllTerminalWindows() -> Bool {
        guard let controller = window?.terminalController else { return true }
        return TerminalController.all
            .filter { $0 !== controller && $0.window?.tabbingMode != .disallowed }
            .allSatisfy {
                controller.windowPresentation.canShareNativeTabGroup(
                    with: $0.windowPresentation
                )
            }
    }

    func prepareToAddTitlebarAccessory(
        _ accessory: NSTitlebarAccessoryViewController,
        isNativeTabBar: Bool
    ) {
        if isNativeTabBar, usesSidebarPresentation {
            accessory.isHidden = true
        }
    }

    /// Keeps the native tab group as a session backend while collapsing its
    /// public titlebar accessory so FLASH does not show two session navigators.
    @discardableResult
    func syncNativeTabBarVisibility() -> Bool {
        guard let window else { return false }
        let shouldHide = usesSidebarPresentation
        for accessory in window.titlebarAccessoryViewControllers
        where window.isTabBar(accessory) {
            if accessory.isHidden != shouldHide {
                accessory.isHidden = shouldHide
            }
        }

        return shouldHide
    }

    func nativeTabBarDidAppear(resetZoomAccessory: NSTitlebarAccessoryViewController) {
        guard let window else { return }
        let isHiddenForSidebar = syncNativeTabBarVisibility()

        let selectedController = window.tabGroup?.selectedWindow?.windowController
            as? TerminalController
        (selectedController ?? window.terminalController)?
            .nativeTabBarDidAppearForSessionSidebar()

        // The hidden tab accessory remains attached in sidebar mode, so its
        // removal callback may never fire. Keep unrelated titlebar accessories.
        if isHiddenForSidebar {
            if window.titlebarAccessoryViewControllers.firstIndex(
                of: resetZoomAccessory
            ) == nil {
                window.addTitlebarAccessoryViewController(resetZoomAccessory)
            }
            return
        }

        // Upstream's native-tab layout requires removing this SwiftUI
        // accessory while the visible tab strip is present.
        if let index = window.titlebarAccessoryViewControllers.firstIndex(
            of: resetZoomAccessory
        ) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    func nativeTabBarDidDisappear(resetZoomAccessory: NSTitlebarAccessoryViewController) {
        guard let window, window.styleMask.contains(.titled) else { return }
        if window.titlebarAccessoryViewControllers.firstIndex(
            of: resetZoomAccessory
        ) == nil {
            window.addTitlebarAccessoryViewController(resetZoomAccessory)
        }
    }

    func configureNativeTabContextMenu(_ menu: NSMenu) {
        guard usesSidebarPresentation,
              let detachItem = menu.items.first(where: {
                  $0.action == NSSelectorFromString("moveTabToNewWindow:")
              }) else { return }

        detachItem.isEnabled = false
        detachItem.toolTip = "Unavailable while the session sidebar is active."
    }

    /// Reapplies the configured titlebar font and FLASH's single-line title
    /// policy whenever AppKit recreates its private title text field.
    func applyTitlebarFont(_ titlebarFont: NSFont?, deferSidebarLayout: Bool = true) {
        guard let window else { return }
        let isSessionSidebar = window.terminalController?
            .usesSessionSidebarTitlebar == true

        // Mutating the native field while SwiftUI installs the sidebar graph
        // can re-enter layout, so coalesce mutations until the next stable pass.
        if deferSidebarLayout, isSessionSidebar {
            titleLayoutGeneration &+= 1
            let generation = titleLayoutGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.titleLayoutGeneration == generation else { return }
                self.applyTitlebarFont(titlebarFont, deferSidebarLayout: false)
            }
            return
        }

        let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
        if let textField = titlebarTextField {
            textField.font = font
            textField.usesSingleLineMode = isSessionSidebar || !window.hasMoreThanOneTabs

            if isSessionSidebar {
                textField.lineBreakMode = .byTruncatingTail
                if !deferSidebarLayout {
                    expandSidebarTitleField(textField)
                }
            }
        }

        // The native strip is hidden in sidebar mode; updating its attributed
        // title would needlessly relayout the shared AppKit tab stack.
        if !isSessionSidebar {
            window.tab.attributedTitle = window.attributedTitle
        }
    }

    private var titlebarTextField: NSTextField? {
        window?.titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")?
            .firstDescendant(withClassName: "NSTextField") as? NSTextField
    }

    private func expandSidebarTitleField(_ textField: NSTextField) {
        guard let window, let titlebarView = textField.superview else { return }

        let rightAccessoryWidth = window.titlebarAccessoryViewControllers.reduce(
            CGFloat.zero
        ) { result, controller in
            guard controller.layoutAttribute == .right ||
                    controller.layoutAttribute == .trailing,
                  !controller.view.isHidden else { return result }
            return result + controller.view.frame.width
        }
        let trailingInset = max(10, rightAccessoryWidth + 10)
        let availableWidth = titlebarView.bounds.maxX - textField.frame.minX - trailingInset
        guard availableWidth > 0 else { return }

        let desiredWidth = ceil(
            textField.cell?.cellSize.width ?? textField.intrinsicContentSize.width
        )
        guard desiredWidth.isFinite else { return }

        let targetWidth = min(desiredWidth, availableWidth)
        var frame = textField.frame
        if abs(frame.width - targetWidth) >= 0.5 {
            frame.size.width = targetWidth
            textField.frame = frame
        }
        textField.toolTip = window.title
    }
}
