import AppKit
import Foundation
import SwiftUI

/// The terminal content root used by the macOS session-sidebar window style.
///
/// Native AppKit tabs each own a separate window and content view. The sidebar
/// renders the application-owned `SessionWorkspace`; the native group is only
/// its presentation adapter. The terminal view remains unchanged on the right.
struct TerminalSessionRootView: View {
    static let minimumSidebarWidth: CGFloat = 220
    static let maximumSidebarWidth: CGFloat = 360
    static let sidebarDividerWidth: CGFloat = 7
    static let fileBrowserDividerWidth: CGFloat = 7
    static let terminalMetadataHeight: CGFloat = 30
    static let minimumTerminalContentWidth: CGFloat = 240

    static var configuredSidebarWidth: CGFloat {
        CGFloat(TerminalSessionSidebarPreferences.storedSidebarWidth)
    }

    static var configuredFileBrowserWidth: CGFloat {
        CGFloat(FlashFileBrowserPreferences.storedWidth)
    }

    static func sidebarChromeWidth(isVisible: Bool) -> CGFloat {
        isVisible ? configuredSidebarWidth + sidebarDividerWidth : 0
    }

    static func fileBrowserChromeWidth(isVisible: Bool) -> CGFloat {
        isVisible ? configuredFileBrowserWidth + fileBrowserDividerWidth : 0
    }

    static func minimumContentWidth(
        isSidebarVisible: Bool,
        isFileBrowserVisible: Bool,
        sidebarWidth: CGFloat,
        fileBrowserWidth: CGFloat
    ) -> CGFloat {
        minimumTerminalContentWidth +
            (isSidebarVisible ? sidebarWidth + sidebarDividerWidth : 0) +
            (isFileBrowserVisible ? fileBrowserWidth + fileBrowserDividerWidth : 0)
    }

    static func constrainedMinimumContentWidth(
        _ requestedWidth: CGFloat,
        visibleFrameWidth: CGFloat?
    ) -> CGFloat {
        guard let visibleFrameWidth, visibleFrameWidth > 0 else {
            return requestedWidth
        }

        // Keep a standard half-screen tile available even when both fixed
        // sidebars are visible. The sidebars remain independently closable if
        // the user wants a larger terminal viewport in that compact layout.
        let tiledWidth = max(minimumTerminalContentWidth, visibleFrameWidth * 0.5)
        return min(requestedWidth, tiledWidth)
    }

    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: TerminalController

    /// A scalar input that changes when AppKit selects this native tab. SwiftUI
    /// can otherwise treat a freshly assigned root with the same observable
    /// objects as unchanged and keep the pre-attachment singleton sidebar.
    let refreshGeneration: UInt

    init(
        ghostty: Ghostty.App,
        controller: TerminalController,
        refreshGeneration: UInt = 0
    ) {
        self.ghostty = ghostty
        self.controller = controller
        self.refreshGeneration = refreshGeneration
    }

    @AppStorage(
        TerminalSessionSidebarPreferences.sessionFontSizeKey,
        store: TerminalSessionSidebarPreferences.store
    ) private var storedSessionFontSize = TerminalSessionSidebarPreferences.defaultSessionFontSize

    @AppStorage(
        TerminalSessionSidebarPreferences.sidebarWidthKey,
        store: TerminalSessionSidebarPreferences.store
    ) private var storedSidebarWidth = TerminalSessionSidebarPreferences.defaultSidebarWidth

    @AppStorage(
        FlashFileBrowserPreferences.widthKey,
        store: FlashFileBrowserPreferences.store
    ) private var storedFileBrowserWidth = FlashFileBrowserPreferences.defaultWidth

    @State private var sidebarWidthAtDragStart: Double?
    @State private var fileBrowserWidthAtDragStart: Double?
    @State private var liveSidebarWidth: Double?
    @State private var liveFileBrowserWidth: Double?

    private var sessionFontSize: Double {
        TerminalSessionSidebarPreferences.sessionFontSize(storedSessionFontSize)
    }

    private var sidebarWidth: Double {
        liveSidebarWidth ??
            TerminalSessionSidebarPreferences.sidebarWidth(storedSidebarWidth)
    }

    private var fileBrowserWidth: Double {
        liveFileBrowserWidth ??
            FlashFileBrowserPreferences.width(storedFileBrowserWidth)
    }

    /// Native tabs retain one root view per AppKit window. Only the selected
    /// root needs live sidebar trees; every root keeps its terminal mounted.
    private var mountsLiveSidebars: Bool {
        // Workspace snapshots publish this compatibility revision whenever
        // native selection changes. Make that invalidation dependency explicit
        // even though selection itself is read through the coordinator.
        _ = controller.sessionSidebarRevision
        return controller.flashSessionTabCoordinator.isSelected(controller)
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionSidebarChrome

            TerminalView(
                ghostty: ghostty,
                viewModel: controller,
                delegate: controller
            )
            .padding(.top, Self.terminalMetadataHeight)
            .overlay(alignment: .top) {
                workingDirectoryHeader
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            fileBrowserChrome
        }
        // Without an explicit AX container, SwiftUI propagates an identifier
        // applied to a layout-only HStack into its accessible descendants.
        // Keep the root queryable without replacing the directory text's own
        // stable identifier, label, and value.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-session-root")
        .background {
            TerminalSessionWindowMinimumWidth(
                minimumWidth: Self.minimumContentWidth(
                    isSidebarVisible: controller.sessionSidebarIsVisible,
                    isFileBrowserVisible: controller.fileBrowserIsVisible,
                    sidebarWidth: CGFloat(sidebarWidth),
                    fileBrowserWidth: CGFloat(fileBrowserWidth)
                )
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// This helper is one stable sibling of `TerminalView`. Switching between
    /// live and inert sidebar content cannot replace the terminal subtree.
    @ViewBuilder
    private var sessionSidebarChrome: some View {
        if controller.sessionSidebarIsVisible {
            if mountsLiveSidebars {
                TerminalSessionSidebar(
                    controller: controller,
                    sessionFontSize: $storedSessionFontSize,
                    refreshGeneration: refreshGeneration
                )
                .frame(width: CGFloat(sidebarWidth))
                .frame(maxHeight: .infinity)

                sidebarDivider
            } else {
                TerminalSidebarPlaceholder()
                    .frame(width: CGFloat(sidebarWidth))
                    .frame(maxHeight: .infinity)

                TerminalSidebarPlaceholder()
                    .frame(width: Self.sidebarDividerWidth)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    /// Mirrors the selected root's exact right-side chrome width without
    /// retaining the Finder-style list model in background native tabs.
    @ViewBuilder
    private var fileBrowserChrome: some View {
        if controller.fileBrowserIsVisible {
            if mountsLiveSidebars {
                fileBrowserDivider

                TerminalFileBrowserContainer(controller: controller)
                    .equatable()
                    .frame(width: CGFloat(fileBrowserWidth))
                    .frame(maxHeight: .infinity)
            } else {
                TerminalSidebarPlaceholder()
                    .frame(width: Self.fileBrowserDividerWidth)
                    .frame(maxHeight: .infinity)

                TerminalSidebarPlaceholder()
                    .frame(width: CGFloat(fileBrowserWidth))
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var sidebarDivider: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
            .frame(width: Self.sidebarDividerWidth)
            .contentShape(Rectangle())
            .gesture(sidebarResizeGesture)
            .onTapGesture(count: 2) {
                liveSidebarWidth = nil
                storedSidebarWidth = TerminalSessionSidebarPreferences.defaultSidebarWidth
            }
            .backport.pointerStyle(.resizeLeftRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session Sidebar Divider")
            .accessibilityValue("\(Int(sidebarWidth)) points")
            .accessibilityHint("Drag to resize the session sidebar. Double-click to reset.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustSidebarWidth(by: 10)
                case .decrement:
                    adjustSidebarWidth(by: -10)
                @unknown default:
                    break
                }
            }
            .accessibilityIdentifier("terminal-session-sidebar.divider")
            .zIndex(1)
    }

    private var sidebarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if sidebarWidthAtDragStart == nil {
                    sidebarWidthAtDragStart = sidebarWidth
                }

                let start = sidebarWidthAtDragStart ?? sidebarWidth
                liveSidebarWidth = TerminalSessionSidebarPreferences.sidebarWidth(
                    start + Double(gesture.translation.width)
                )
            }
            .onEnded { _ in
                if let liveSidebarWidth {
                    storedSidebarWidth = liveSidebarWidth
                }
                liveSidebarWidth = nil
                sidebarWidthAtDragStart = nil
            }
    }

    private func adjustSidebarWidth(by amount: Double) {
        storedSidebarWidth = TerminalSessionSidebarPreferences.sidebarWidth(sidebarWidth + amount)
    }

    private var fileBrowserDivider: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
            .frame(width: Self.fileBrowserDividerWidth)
            .contentShape(Rectangle())
            .gesture(fileBrowserResizeGesture)
            .onTapGesture(count: 2) {
                liveFileBrowserWidth = nil
                storedFileBrowserWidth = FlashFileBrowserPreferences.defaultWidth
            }
            .backport.pointerStyle(.resizeLeftRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("File Sidebar Divider")
            .accessibilityValue("\(Int(fileBrowserWidth)) points")
            .accessibilityHint("Drag to resize the file sidebar. Double-click to reset.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustFileBrowserWidth(by: 10)
                case .decrement:
                    adjustFileBrowserWidth(by: -10)
                @unknown default:
                    break
                }
            }
            .accessibilityIdentifier("terminal-file-sidebar.divider")
            .zIndex(1)
    }

    private var fileBrowserResizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if fileBrowserWidthAtDragStart == nil {
                    fileBrowserWidthAtDragStart = fileBrowserWidth
                }

                let start = fileBrowserWidthAtDragStart ?? fileBrowserWidth
                liveFileBrowserWidth = FlashFileBrowserPreferences.width(
                    start - Double(gesture.translation.width)
                )
            }
            .onEnded { _ in
                if let liveFileBrowserWidth {
                    storedFileBrowserWidth = liveFileBrowserWidth
                }
                liveFileBrowserWidth = nil
                fileBrowserWidthAtDragStart = nil
            }
    }

    private func adjustFileBrowserWidth(by amount: Double) {
        storedFileBrowserWidth = FlashFileBrowserPreferences.width(
            fileBrowserWidth + amount
        )
    }

    @ViewBuilder
    private var workingDirectoryHeader: some View {
        TerminalWorkingDirectoryHeader(
            controller: controller,
            metadata: controller.sessionMetadata,
            fontSize: sessionFontSize,
            height: Self.terminalMetadataHeight
        )
    }
}

/// Observes only the metadata needed by the titlebar. Provider polling can
/// update this view without rebuilding the terminal renderer or both sidebars.
private struct TerminalWorkingDirectoryHeader: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var metadata: TerminalSessionMetadataMonitor
    let fontSize: Double
    let height: CGFloat

    var body: some View {
        let url = metadata.workingDirectory
        let displayPath = SessionWorkingDirectory.displayPath(for: url)

        HStack(spacing: 6) {
            Spacer(minLength: 8)

            Image(systemName: "folder")
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemTeal))
                .accessibilityHidden(true)

            Text("Directory")
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemTeal))
                .lineLimit(1)

            Text(displayPath ?? "Loading…")
                .font(.system(
                    size: fontSize,
                    weight: .regular,
                    design: .monospaced
                ))
                .foregroundStyle(displayPath == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .frame(minWidth: 80, alignment: .trailing)
                .help(url?.standardizedFileURL.path ?? "Waiting for the shell working directory")
                .accessibilityLabel("Working Directory")
                .accessibilityValue(url?.standardizedFileURL.path ?? "Loading")
                .accessibilityIdentifier("terminal-session-working-directory.text")

            Button {
                controller.toggleFileBrowser()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: fontSize, weight: .regular))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                controller.fileBrowserIsVisible
                    ? Color(nsColor: .systemTeal)
                    : Color.secondary
            )
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.06))
            )
            .help(controller.fileBrowserIsVisible ? "Hide File Sidebar" : "Show File Sidebar")
            .accessibilityLabel(
                controller.fileBrowserIsVisible ? "Hide File Sidebar" : "Show File Sidebar"
            )
            .accessibilityValue(controller.fileBrowserIsVisible ? "Shown" : "Hidden")
            .accessibilityIdentifier("terminal-file-sidebar.toggle")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        // This HStack has its own identifier as well as an identified child.
        // Make the hierarchy explicit so the header identifier cannot overwrite
        // the working-directory StaticText exposed to UI automation.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-session-working-directory")
    }
}

/// Prevents high-frequency terminal metadata changes from rebuilding the
/// Finder-style file list. The browser observes its narrow session state and
/// model directly, so equal controller identity is the only parent input that
/// matters while this sidebar remains mounted.
private struct TerminalFileBrowserContainer: View, Equatable {
    let controller: TerminalController

    static func == (
        lhs: TerminalFileBrowserContainer,
        rhs: TerminalFileBrowserContainer
    ) -> Bool {
        lhs.controller === rhs.controller
    }

    var body: some View {
        FlashFileBrowserSidebar(controller: controller) {
            controller.toggleFileBrowser()
        }
    }
}

/// Preserves native-tab geometry while omitting the expensive sidebar view
/// trees from background roots. It deliberately exposes no interaction or AX
/// nodes because the corresponding AppKit window is not selected.
private struct TerminalSidebarPlaceholder: View {
    var body: some View {
        Color(nsColor: .controlBackgroundColor)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Keeps both fixed-width sidebars and a usable terminal viewport on screen.
/// AppKit applies this constraint during live resizing and when a sidebar is
/// shown or resized. The requested width is capped so ordinary half-screen
/// tiling remains available, and any pre-existing AppKit minimum is preserved.
private struct TerminalSessionWindowMinimumWidth: NSViewRepresentable {
    let minimumWidth: CGFloat

    func makeNSView(context: Context) -> WindowMinimumWidthView {
        let view = WindowMinimumWidthView()
        view.minimumWidth = minimumWidth
        return view
    }

    func updateNSView(_ nsView: WindowMinimumWidthView, context: Context) {
        guard nsView.minimumWidth != minimumWidth else { return }
        nsView.minimumWidth = minimumWidth
    }

    final class WindowMinimumWidthView: NSView {
        private weak var trackedWindow: NSWindow?
        private var baselineMinimumWidth: CGFloat = 0

        var minimumWidth: CGFloat = 0 {
            didSet {
                guard minimumWidth != oldValue else { return }
                applyMinimumWidth()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMinimumWidth()
        }

        private func applyMinimumWidth() {
            guard let window, minimumWidth > 0 else { return }
            if trackedWindow !== window {
                trackedWindow = window
                baselineMinimumWidth = window.contentMinSize.width
            }

            let constrainedWidth = TerminalSessionRootView.constrainedMinimumContentWidth(
                minimumWidth,
                visibleFrameWidth: window.screen?.visibleFrame.width
            )
            let appliedWidth = max(baselineMinimumWidth, constrainedWidth)

            var minimumSize = window.contentMinSize
            if minimumSize.width != appliedWidth {
                minimumSize.width = appliedWidth
                window.contentMinSize = minimumSize
            }

            // Only correct an undersized window before it is presented. Never
            // jump a visible/tiled window when the user toggles a sidebar.
            guard !window.isVisible,
                  window.contentLayoutRect.width < appliedWidth else { return }
            var contentSize = window.contentLayoutRect.size
            contentSize.width = appliedWidth
            window.setContentSize(contentSize)
        }
    }
}
