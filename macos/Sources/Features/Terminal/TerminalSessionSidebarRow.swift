import AppKit
import Foundation
import SwiftUI

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

struct TerminalSessionSidebarRow: View {
    private static let contentHeight: CGFloat = 56
    private static let terminalAccentColors: [NSColor] = [
        .systemIndigo,
        .systemPurple,
        .systemTeal,
        .systemPink,
        .systemBlue,
    ]

    private let hostController: TerminalController
    @ObservedObject private var sessionController: TerminalController
    @ObservedObject private var sessionMetadata: TerminalSessionMetadataMonitor
    private let allControllers: [TerminalController]
    private let isSelected: Bool
    private let fontSize: Double

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var isRenameFieldFocused: Bool

    init(
        hostController: TerminalController,
        sessionController: TerminalController,
        sessionMetadata: TerminalSessionMetadataMonitor,
        allControllers: [TerminalController],
        isSelected: Bool,
        fontSize: Double
    ) {
        self.hostController = hostController
        _sessionController = ObservedObject(wrappedValue: sessionController)
        _sessionMetadata = ObservedObject(wrappedValue: sessionMetadata)
        self.allControllers = allControllers
        self.isSelected = isSelected
        self.fontSize = fontSize
    }

    private var rowIdentifier: String {
        "terminal-session-sidebar.row.\(sessionController.sessionID)"
    }

    private var title: String {
        TerminalSessionName.displayName(for: sessionController.titleOverride)
    }

    private var tabColor: NSColor? {
        (sessionController.window as? TerminalWindow)?.tabColor.displayColor
    }

    private var sessionTool: TerminalSessionTool {
        sessionMetadata.tool
    }

    private var activityStatus: TerminalSessionActivityStatus {
        sessionMetadata.activityStatus
    }

    private var instruction: String {
        sessionMetadata.lastInstruction ?? "No previous instruction"
    }

    private var hasInstruction: Bool {
        sessionMetadata.lastInstruction != nil
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
                    // Session names commonly contain commands, paths, and
                    // product names. Inline prediction can alter whitespace
                    // while the adjacent save button ends editing.
                    .autocorrectionDisabled()
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
                .scaledToFit()
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
                    commitRenameFromButton()
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
                } else {
                    // Keep the rename target in the same slot when hover adds
                    // the close button. Without a reserved second slot, the
                    // pencil moves between pointer-down and pointer-up and the
                    // click can accidentally close the session instead.
                    Color.clear
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
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

    /// A button click can arrive while an input method still owns marked text.
    /// End editing first and commit on the following main-loop turn so SwiftUI
    /// has published the final composed value into `draftTitle`. Reading the
    /// binding immediately can otherwise drop the last composed word.
    private func commitRenameFromButton() {
        guard isRenaming else { return }

        isRenameFieldFocused = false
        DispatchQueue.main.async {
            guard isRenaming else { return }
            commitRename(restoreTerminalFocus: true)
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
