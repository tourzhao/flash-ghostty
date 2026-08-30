import AppKit
import Foundation
import SwiftUI

struct TerminalSessionSidebar: View {
    @ObservedObject private var controller: TerminalController
    @Binding private var sessionFontSize: Double
    private let refreshGeneration: UInt
    @State private var searchText = ""
    @State private var isFontSizePopoverPresented = false

    init(
        controller: TerminalController,
        sessionFontSize: Binding<Double>,
        refreshGeneration: UInt
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        _sessionFontSize = sessionFontSize
        self.refreshGeneration = refreshGeneration
    }

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
                        ForEach(visibleSessions, id: \.sessionID) { session in
                            TerminalSessionSidebarRow(
                                hostController: controller,
                                sessionController: session,
                                sessionMetadata: session.sessionMetadata,
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
