import AppKit
import Foundation
import SwiftUI

/// Global, user-adjustable presentation preferences for the session sidebar.
/// These are AppKit UI preferences rather than terminal configuration, so they
/// live in Ghostty's UserDefaults domain and apply to every sidebar window.
enum TerminalSessionSidebarPreferences {
    static let store = UserDefaults.ghostty

    static let sessionFontSizeKey = "SessionSidebarSessionFontSize"
    static let sidebarWidthKey = "SessionSidebarWidth"

    static let defaultSessionFontSize = 13.0
    static let defaultSidebarWidth = 260.0
    static let sessionFontSizeRange = 9.0...18.0
    static let sidebarWidthRange = 220.0...360.0
    static let fontSizeStep = 0.5

    static func sessionFontSize(_ value: Double) -> Double {
        sanitized(value, defaultValue: defaultSessionFontSize, range: sessionFontSizeRange)
    }

    static func sidebarWidth(_ value: Double) -> Double {
        sanitized(value, defaultValue: defaultSidebarWidth, range: sidebarWidthRange)
    }

    static var storedSessionFontSize: Double {
        let value = (store.object(forKey: sessionFontSizeKey) as? NSNumber)?.doubleValue
            ?? defaultSessionFontSize
        return sessionFontSize(value)
    }

    static var storedSidebarWidth: Double {
        let value = (store.object(forKey: sidebarWidthKey) as? NSNumber)?.doubleValue
            ?? defaultSidebarWidth
        return sidebarWidth(value)
    }

    static func label(for value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func sanitized(
        _ value: Double,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The name shown in a session-sidebar row. Terminal-generated window titles
/// often contain the working directory, so only an explicit user override is
/// treated as a session name.
enum TerminalSessionName {
    static let unnamed = "Blank"
    static let sidebarWindowTitle = "FLASH-Ghostty"

    static func windowTitle(isSidebar: Bool, regularTitle: String) -> String {
        isSidebar ? sidebarWindowTitle : regularTitle
    }

    static func displayName(for titleOverride: String?) -> String {
        guard let title = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return unnamed }
        return title
    }
}

private enum TerminalSessionToolIcons {
    static let codex = applicationIcon(bundleIdentifier: "com.openai.codex")
    static let claudeCode = applicationIcon(bundleIdentifier: "com.anthropic.claudefordesktop")

    private static func applicationIcon(bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }

        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The terminal content root used by the macOS session-sidebar window style.
///
/// Native AppKit tabs each own a separate window and content view. The sidebar
/// renders the application-owned `SessionWorkspace`; the native group is only
/// its presentation adapter. The terminal view remains unchanged on the right.
struct TerminalSessionRootView: View {
    static let minimumSidebarWidth: CGFloat = 220
    static let maximumSidebarWidth: CGFloat = 360
    static let sidebarDividerWidth: CGFloat = 7
    static let terminalMetadataHeight: CGFloat = 30

    static var configuredSidebarWidth: CGFloat {
        CGFloat(TerminalSessionSidebarPreferences.storedSidebarWidth)
    }

    static func sidebarChromeWidth(isVisible: Bool) -> CGFloat {
        isVisible ? configuredSidebarWidth + sidebarDividerWidth : 0
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

    @State private var sidebarWidthAtDragStart: Double?

    private var sessionFontSize: Double {
        TerminalSessionSidebarPreferences.sessionFontSize(storedSessionFontSize)
    }

    private var sidebarWidth: Double {
        TerminalSessionSidebarPreferences.sidebarWidth(storedSidebarWidth)
    }

    var body: some View {
        let _ = refreshGeneration
        HStack(spacing: 0) {
            if controller.sessionSidebarIsVisible {
                TerminalSessionSidebar(
                    controller: controller,
                    sessionFontSize: $storedSessionFontSize,
                    refreshGeneration: refreshGeneration
                )
                .frame(width: CGFloat(sidebarWidth))
                .frame(maxHeight: .infinity)

                sidebarDivider
            }

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
        }
        // Without an explicit AX container, SwiftUI propagates an identifier
        // applied to a layout-only HStack into its accessible descendants.
        // Keep the root queryable without replacing the directory text's own
        // stable identifier, label, and value.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-session-root")
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
                storedSidebarWidth = TerminalSessionSidebarPreferences.sidebarWidth(
                    start + Double(gesture.translation.width)
                )
            }
            .onEnded { _ in
                sidebarWidthAtDragStart = nil
            }
    }

    private func adjustSidebarWidth(by amount: Double) {
        storedSidebarWidth = TerminalSessionSidebarPreferences.sidebarWidth(sidebarWidth + amount)
    }

    @ViewBuilder
    private var workingDirectoryHeader: some View {
        let url = controller.sessionWorkingDirectory
        let displayPath = SessionWorkingDirectory.displayPath(for: url)

        HStack(spacing: 6) {
            Spacer(minLength: 8)

            Image(systemName: "folder")
                .font(.system(size: sessionFontSize, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemTeal))
                .accessibilityHidden(true)

            Text("Directory")
                .font(.system(size: sessionFontSize, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemTeal))
                .lineLimit(1)

            Text(displayPath ?? "Loading…")
                .font(.system(
                    size: sessionFontSize,
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
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: Self.terminalMetadataHeight)
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

enum SessionWorkingDirectory {
    static func displayPath(for url: URL?) -> String? {
        guard let url else { return nil }

        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return nil }
        return path
    }
}

private struct TerminalSessionSidebar: View {
    @ObservedObject var controller: TerminalController
    @Binding var sessionFontSize: Double
    let refreshGeneration: UInt
    @State private var searchText = ""
    @State private var isFontSizePopoverPresented = false

    private var effectiveSessionFontSize: Double {
        TerminalSessionSidebarPreferences.sessionFontSize(sessionFontSize)
    }

    private var sessionControllers: [TerminalController] {
        // Reading the revision makes tab membership and ordering mutations an
        // explicit dependency of this view, even though the rows are computed.
        _ = refreshGeneration
        _ = controller.sessionSidebarRevision
        return controller.sessionSidebarControllers
    }

    var body: some View {
        let sessions = sessionControllers
        let visibleSessions = filteredSessions(sessions)

        VStack(spacing: 0) {
            header(sessionCount: sessions.count)
            searchField

            Divider()
                .padding(.top, 10)

            if visibleSessions.isEmpty {
                emptySearchResult
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleSessions, id: \.sessionSidebarIdentity) { session in
                            TerminalSessionSidebarRow(
                                hostController: controller,
                                sessionController: session,
                                allControllers: sessions,
                                isSelected: isSessionSelected(session),
                                fontSize: effectiveSessionFontSize
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("terminal-session-sidebar.list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        // Establish a semantic boundary before assigning the identifier.
        // Without this, SwiftUI flattens the VStack and the outer
        // `terminal-session-root` identifier propagates to its children,
        // leaving no accessibility element for the sidebar itself.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session Sidebar")
        .accessibilityIdentifier("terminal-session-sidebar")
    }

    @ViewBuilder
    private func header(sessionCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(.system(size: 15, weight: .regular))

            Text("\(sessionCount)")
                .font(.caption2.weight(.regular))
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .systemPurple))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .systemPurple).opacity(0.14))
                )
                .accessibilityLabel("\(sessionCount) sessions")
                .accessibilityIdentifier("terminal-session-sidebar.count")

            Spacer(minLength: 8)

            fontSizeButton

            Button {
                controller.newSessionFromSidebar()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .systemBlue).opacity(0.14))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Session")
            .accessibilityLabel("New Session")
            .accessibilityIdentifier("terminal-session-sidebar.new")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var fontSizeButton: some View {
        Button {
            isFontSizePopoverPresented.toggle()
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemPurple))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .systemPurple).opacity(0.14))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isFontSizePopoverPresented, arrowEdge: .bottom) {
            TerminalSessionFontSizePopover(
                value: effectiveSessionFontSize,
                onCommit: { value in
                    sessionFontSize = value
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak controller] in
                        controller?.sessionSidebarFontSizeDidChange()
                    }
                }
            )
        }
        .help("Adjust Session Text Size")
        .accessibilityLabel("Adjust Session Text Size")
        .accessibilityIdentifier("terminal-session-sidebar.font-size")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search sessions", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("Search Sessions")
                .accessibilityIdentifier("terminal-session-sidebar.search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
                .accessibilityIdentifier("terminal-session-sidebar.clear-search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }

    private var emptySearchResult: some View {
        VStack(spacing: 9) {
            Spacer()

            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("No matching sessions")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !searchText.isEmpty {
                Button("Clear Search") {
                    searchText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .accessibilityIdentifier("terminal-session-sidebar.empty-clear-search")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-session-sidebar.empty")
    }

    private func filteredSessions(_ sessions: [TerminalController]) -> [TerminalController] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }

        return sessions.filter { session in
            let title = TerminalSessionName.displayName(for: session.titleOverride)
            return title.localizedCaseInsensitiveContains(query)
        }
    }

    private func isSessionSelected(_ session: TerminalController) -> Bool {
        controller.isSessionSelectedFromSidebar(session)
    }
}

/// Keeps font-size adjustments inside the popover's own AttributeGraph. The
/// main sidebar receives one committed value only after the popover has fully
/// closed, so changing text metrics cannot re-enter the presenting layout.
private struct TerminalSessionFontSizePopover: View {
    @Environment(\.dismiss) private var dismiss

    private let initialValue: Double
    private let onCommit: (Double) -> Void
    @State private var draftValue: Double

    init(value: Double, onCommit: @escaping (Double) -> Void) {
        let value = TerminalSessionSidebarPreferences.sessionFontSize(value)
        self.initialValue = value
        self.onCommit = onCommit
        _draftValue = State(initialValue: value)
    }

    private var effectiveValue: Double {
        TerminalSessionSidebarPreferences.sessionFontSize(draftValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Text Size")
                .font(.system(size: 13, weight: .regular))

            HStack(spacing: 8) {
                Text("Session text")
                    .font(.system(size: 11, weight: .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)

                controlButton(
                    systemName: "textformat.size.smaller",
                    help: "Decrease Session text font size",
                    identifier: "terminal-session-sidebar.font-size.session.decrease"
                ) {
                    adjust(by: -TerminalSessionSidebarPreferences.fontSizeStep)
                }
                .disabled(
                    effectiveValue <=
                        TerminalSessionSidebarPreferences.sessionFontSizeRange.lowerBound
                )

                Text("\(TerminalSessionSidebarPreferences.label(for: effectiveValue)) pt")
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 45)
                    .accessibilityLabel("Session text font size")
                    .accessibilityValue(
                        "\(TerminalSessionSidebarPreferences.label(for: effectiveValue)) points"
                    )
                    .accessibilityIdentifier(
                        "terminal-session-sidebar.font-size.session.value"
                    )

                controlButton(
                    systemName: "textformat.size.larger",
                    help: "Increase Session text font size",
                    identifier: "terminal-session-sidebar.font-size.session.increase"
                ) {
                    adjust(by: TerminalSessionSidebarPreferences.fontSizeStep)
                }
                .disabled(
                    effectiveValue >=
                        TerminalSessionSidebarPreferences.sessionFontSizeRange.upperBound
                )

                controlButton(
                    systemName: "arrow.counterclockwise",
                    help: "Reset Session text font size",
                    identifier: "terminal-session-sidebar.font-size.session.reset"
                ) {
                    draftValue = TerminalSessionSidebarPreferences.defaultSessionFontSize
                }
                .disabled(
                    effectiveValue ==
                        TerminalSessionSidebarPreferences.defaultSessionFontSize
                )
            }

            Text(
                "Applies to session names, working directory, and window title " +
                    "in every sidebar window after this popover closes."
            )
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("terminal-session-sidebar.font-size.done")
            }
        }
        .padding(14)
        .frame(width: 290)
        .accessibilityIdentifier("terminal-session-sidebar.font-size.popover")
        .onDisappear {
            let value = effectiveValue
            guard value != initialValue else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                onCommit(value)
            }
        }
    }

    private func controlButton(
        systemName: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .regular))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }

    private func adjust(by amount: Double) {
        draftValue = TerminalSessionSidebarPreferences.sessionFontSize(
            effectiveValue + amount
        )
    }
}

private struct TerminalSessionSidebarRow: View {
    private static let contentHeight: CGFloat = 56
    private static let terminalAccentColors: [NSColor] = [
        .systemIndigo,
        .systemPurple,
        .systemTeal,
        .systemPink,
        .systemBlue,
    ]

    let hostController: TerminalController
    @ObservedObject var sessionController: TerminalController
    let allControllers: [TerminalController]
    let isSelected: Bool
    let fontSize: Double

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var isRenameFieldFocused: Bool

    private var rowIdentifier: String {
        "terminal-session-sidebar.row.\(sessionController.sessionSidebarIdentity)"
    }

    private var title: String {
        TerminalSessionName.displayName(for: sessionController.titleOverride)
    }

    private var tabColor: NSColor? {
        (sessionController.window as? TerminalWindow)?.tabColor.displayColor
    }

    private var sessionTool: TerminalSessionTool {
        sessionController.sessionTool
    }

    private var activityStatus: TerminalSessionActivityStatus {
        sessionController.sessionActivityStatus
    }

    private var instruction: String {
        sessionController.sessionLastInstruction ?? "No previous instruction"
    }

    private var hasInstruction: Bool {
        sessionController.sessionLastInstruction != nil
    }

    private var sessionNameFontSize: Double {
        min(12, max(9, fontSize * 0.75))
    }

    private var sessionAccentColor: Color {
        switch sessionTool {
        case .codex:
            return Color(nsColor: .systemTeal)
        case .claudeCode:
            return Color(nsColor: .systemOrange)
        case .terminal:
            let index = allControllers.firstIndex(where: { $0 === sessionController }) ?? 0
            let color = Self.terminalAccentColors[index % Self.terminalAccentColors.count]
            return Color(nsColor: color)
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return sessionAccentColor.opacity(0.20)
        }

        return isHovered ? sessionAccentColor.opacity(0.09) : .clear
    }

    private var canCloseOtherSessions: Bool {
        allControllers.count > 1
    }

    private var canCloseSessionsToRight: Bool {
        guard let index = allControllers.firstIndex(where: { $0 === sessionController }) else {
            return false
        }

        return index < allControllers.count - 1
    }

    var body: some View {
        HStack(spacing: 6) {
            sessionNameControl
            trailingControls
        }
        // The name owns the first line; the icon and last instruction share
        // the second. This fixed height keeps spacing stable across 9...18 pt.
        .frame(height: Self.contentHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? sessionAccentColor.opacity(0.50) : Color.clear,
                    lineWidth: 1
                )
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(sessionAccentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: isRenameFieldFocused) { focused in
            guard !focused, isRenaming else { return }

            // Defer so a cancel-button click can exit editing before focus
            // loss is interpreted as a commit.
            DispatchQueue.main.async {
                guard isRenaming, !isRenameFieldFocused else { return }
                commitRename(restoreTerminalFocus: false)
            }
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rowIdentifier)
    }

    @ViewBuilder
    private var sessionNameControl: some View {
        if isRenaming {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Session name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: sessionNameFontSize, weight: .regular))
                    .focused($isRenameFieldFocused)
                    .onSubmit {
                        commitRename(restoreTerminalFocus: true)
                    }
                    .onExitCommand {
                        cancelRename(restoreTerminalFocus: true)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(sessionAccentColor.opacity(0.75), lineWidth: 1)
                    )
                    .accessibilityLabel("Session Name")
                    .accessibilityHint("Leave blank to display Blank in the sidebar")
                    .accessibilityIdentifier("\(rowIdentifier).name-field")

                HStack(spacing: 10) {
                    sessionIcon
                    instructionText
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                hostController.selectSessionFromSidebar(sessionController)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: sessionNameFontSize, weight: .regular))
                        .foregroundStyle(isSelected ? sessionAccentColor : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        sessionIcon
                        instructionText
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(title)\n\(instruction)")
            .accessibilityLabel("Select \(title)")
            .accessibilityValue(
                accessibilityValue
            )
            .accessibilityHint("Select session")
            .accessibilityIdentifier("\(rowIdentifier).select")
        }
    }

    private var instructionText: some View {
        Text(instruction)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(hasInstruction ? .primary : .tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .help(instruction)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isSelected { parts.append("Selected") }
        parts.append(activityStatusLabel)
        parts.append("Last instruction: \(instruction)")
        return parts.joined(separator: ", ")
    }

    private var activityStatusLabel: String {
        switch activityStatus {
        case .ready: return "Ready"
        case .active: return "Active"
        case .paused: return "Needs input"
        case .completed: return "Complete"
        case .failed: return "Failed"
        }
    }

    private var activityStatusSystemName: String {
        switch activityStatus {
        case .ready: return "circle.fill"
        case .active: return "bolt.fill"
        case .paused: return "pause.fill"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var activityStatusColor: Color {
        switch activityStatus {
        case .ready: return Color(nsColor: .systemGray)
        case .active: return Color(nsColor: .systemBlue)
        case .paused: return Color(nsColor: .systemOrange)
        case .completed: return Color(nsColor: .systemGreen)
        case .failed: return Color(nsColor: .systemRed)
        }
    }

    private var sessionIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(sessionIconBackground)
                .frame(width: 30, height: 30)

            sessionIconGlyph
                .frame(width: 30, height: 30)
        }
        .frame(width: 30, height: 30)
        .overlay(alignment: .topTrailing) {
            if let tabColor {
                Circle()
                    .fill(Color(nsColor: tabColor))
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1)
                    )
                    .offset(x: 2, y: -2)
                    .accessibilityLabel("Tab color")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(activityStatusColor.opacity(0.18))
                .frame(width: 13, height: 13)
                .overlay(
                    Circle()
                        .stroke(activityStatusColor.opacity(0.85), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: activityStatusSystemName)
                        .font(.system(size: 7, weight: .regular))
                        .foregroundStyle(activityStatusColor)
                )
                .offset(x: 2, y: 2)
        }
        .accessibilityHidden(true)
    }

    private var sessionIconBackground: Color {
        sessionAccentColor.opacity(isSelected ? 0.28 : 0.16)
    }

    @ViewBuilder
    private var sessionIconGlyph: some View {
        switch sessionTool {
        case .codex:
            if let icon = TerminalSessionToolIcons.codex {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
            } else {
                Text("C")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(sessionAccentColor)
            }
        case .claudeCode:
            if let icon = TerminalSessionToolIcons.claudeCode {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
            } else {
                Text("✳")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(sessionAccentColor)
            }
        case .terminal:
            ghosttyIconImage()
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 2) {
            if isRenaming {
                rowActionButton(
                    systemName: "checkmark",
                    help: "Save Session Name",
                    identifier: "\(rowIdentifier).save-name"
                ) {
                    commitRename(restoreTerminalFocus: true)
                }

                rowActionButton(
                    systemName: "xmark",
                    help: "Cancel Rename",
                    identifier: "\(rowIdentifier).cancel-name"
                ) {
                    cancelRename(restoreTerminalFocus: true)
                }
            } else if isHovered || isSelected {
                rowActionButton(
                    systemName: "pencil",
                    help: "Rename Session",
                    identifier: "\(rowIdentifier).rename",
                    action: beginRename
                )

                if isHovered {
                    rowActionButton(
                        systemName: "xmark",
                        help: "Close Session",
                        identifier: "\(rowIdentifier).close"
                    ) {
                        hostController.closeSessionFromSidebar(sessionController)
                    }
                } else if sessionController.bell {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.orange)
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Bell active")
                }
            } else if sessionController.bell {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.orange)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Bell active")
            }
        }
        .frame(width: 46, height: Self.contentHeight, alignment: .trailing)
    }

    private func rowActionButton(
        systemName: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .regular))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.09))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Rename Session") {
            // Wait for the context menu to dismiss before requesting focus.
            DispatchQueue.main.async {
                beginRename()
            }
        }

        Divider()

        Button("Close Other Sessions") {
            hostController.closeOtherSessionsFromSidebar(sessionController)
        }
        .disabled(!canCloseOtherSessions)

        Button("Close Sessions to the Right") {
            hostController.closeSessionsToRightFromSidebar(sessionController)
        }
        .disabled(!canCloseSessionsToRight)

        Divider()

        Button("Close Session", role: .destructive) {
            hostController.closeSessionFromSidebar(sessionController)
        }
    }

    private func beginRename() {
        guard !isRenaming else { return }

        draftTitle = sessionController.titleOverride ?? ""
        isRenaming = true

        DispatchQueue.main.async {
            guard isRenaming else { return }
            isRenameFieldFocused = true
        }
    }

    private func commitRename(restoreTerminalFocus: Bool) {
        guard isRenaming else { return }

        let newTitle = draftTitle
        isRenaming = false
        isRenameFieldFocused = false
        hostController.setSessionNameFromSidebar(sessionController, name: newTitle)

        if restoreTerminalFocus {
            DispatchQueue.main.async {
                hostController.restoreTerminalFocusAfterSidebarRename()
            }
        }
    }

    private func cancelRename(restoreTerminalFocus: Bool) {
        guard isRenaming else { return }

        isRenaming = false
        isRenameFieldFocused = false

        if restoreTerminalFocus {
            DispatchQueue.main.async {
                hostController.restoreTerminalFocusAfterSidebarRename()
            }
        }
    }
}

private extension TerminalController {
    var sessionSidebarIdentity: SessionWorkspace.SessionID {
        sessionID
    }
}
