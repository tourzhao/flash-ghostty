//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }
}

struct TerminalSessionSidebarPreferencesTests {
    @Test func sessionFontSizeIsClampedAndRejectsNonFiniteValues() {
        #expect(TerminalSessionSidebarPreferences.sessionFontSize(8) == 9)
        #expect(TerminalSessionSidebarPreferences.sessionFontSize(13.5) == 13.5)
        #expect(TerminalSessionSidebarPreferences.sessionFontSize(19) == 18)
        #expect(
            TerminalSessionSidebarPreferences.sessionFontSize(.nan) ==
                TerminalSessionSidebarPreferences.defaultSessionFontSize
        )
    }

    @Test func fontSizeLabelsPreserveHalfPointSteps() {
        #expect(TerminalSessionSidebarPreferences.label(for: 13) == "13")
        #expect(TerminalSessionSidebarPreferences.label(for: 10.5) == "10.5")
    }

    @Test func sidebarWidthIsSharedWithinSafeBounds() {
        #expect(TerminalSessionSidebarPreferences.sidebarWidth(200) == 220)
        #expect(TerminalSessionSidebarPreferences.sidebarWidth(312) == 312)
        #expect(TerminalSessionSidebarPreferences.sidebarWidth(400) == 360)
        #expect(
            TerminalSessionSidebarPreferences.sidebarWidth(.nan) ==
                TerminalSessionSidebarPreferences.defaultSidebarWidth
        )
    }

    @Test func hiddenSidebarRemovesItsWidthAndDividerWithoutChangingStoredWidth() {
        let storedWidth = TerminalSessionSidebarPreferences.storedSidebarWidth

        #expect(TerminalSessionRootView.sidebarChromeWidth(isVisible: false) == 0)
        #expect(
            TerminalSessionRootView.sidebarChromeWidth(isVisible: true) ==
                CGFloat(storedWidth) + TerminalSessionRootView.sidebarDividerWidth
        )
        #expect(TerminalSessionSidebarPreferences.storedSidebarWidth == storedWidth)
    }

    @Test func workingDirectoryDisplayUsesTheFullStandardizedPath() {
        #expect(SessionWorkingDirectory.displayPath(for: nil) == nil)

        let temporaryDirectoryAlias = URL(fileURLWithPath: "/private/tmp")
        #expect(
            SessionWorkingDirectory.displayPath(for: temporaryDirectoryAlias) ==
                temporaryDirectoryAlias.standardizedFileURL.path
        )

        #expect(
            SessionWorkingDirectory.displayPath(
                for: URL(fileURLWithPath: "/private/tmp/ghostty/../sidebar")
            ) == "/private/tmp/sidebar"
        )

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(SessionWorkingDirectory.displayPath(for: home) == home.path)
        #expect(SessionWorkingDirectory.displayPath(for: home) != "~")
    }
}

struct TerminalSessionNameTests {
    @Test func sidebarWindowUsesTheApplicationNameInsteadOfSessionMetadata() {
        for title in ["Blank", "Named Session", "/private/tmp", "Codex — project"] {
            #expect(
                TerminalSessionName.windowTitle(
                    isSidebar: true,
                    regularTitle: title) == "FLASH-Ghostty"
            )
        }
    }

    @Test func nonSidebarWindowKeepsItsSessionTitle() {
        #expect(
            TerminalSessionName.windowTitle(
                isSidebar: false,
                regularTitle: "Named Session") == "Named Session"
        )
    }

    @Test func unnamedSessionsDisplayBlankInsteadOfTerminalMetadata() {
        #expect(TerminalSessionName.displayName(for: nil) == "Blank")
        #expect(TerminalSessionName.displayName(for: "") == "Blank")
        #expect(TerminalSessionName.displayName(for: "   \n") == "Blank")
    }

    @Test func explicitSessionNamesAreTrimmedAndDisplayed() {
        #expect(TerminalSessionName.displayName(for: "  Sidebar work  ") == "Sidebar work")
    }
}

struct TerminalSessionToolTests {
    @Test func detectsCodexFromDynamicTerminalTitle() {
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "codex") == .codex)
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "Codex — project") == .codex)
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "Codex — project",
                foregroundProcessName: "/opt/homebrew/bin/node"
            ) == .codex
        )
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "⠙ tourzhao",
                foregroundProcessName: "codex"
            ) == .codex
        )
    }

    @Test func detectsClaudeCodeFromDynamicTerminalTitle() {
        #expect(
            TerminalSessionTool.detect(fromDynamicTitle: "✳ Claude Code") == .claudeCode
        )
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "claude-code") == .claudeCode)
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "✳ Claude Code",
                foregroundProcessName: "node"
            ) == .claudeCode
        )
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "~/project",
                foregroundProcessName: "claude"
            ) == .claudeCode
        )
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "~/project",
                foregroundProcessName:
                    "/Users/example/.local/share/claude/versions/2.1.241"
            ) == .claudeCode
        )
    }

    @Test func leavesOrdinaryShellTitlesAsTerminalSessions() {
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "~/src/ghostty") == .terminal)
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "myclaudette") == .terminal)
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "/tmp/codex") == .terminal)
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "/tmp/claude") == .terminal)
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "Codex — project",
                foregroundProcessName: "zsh"
            ) == .terminal
        )
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "✳ Claude Code",
                foregroundProcessName: "vim"
            ) == .terminal
        )
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "~/src/ghostty",
                foregroundProcessName: "node"
            ) == .terminal
        )
        #expect(TerminalSessionTool.detect(fromDynamicTitle: "") == .terminal)
    }
}

struct TerminalSessionActivityClassifierTests {
    @Test func structuredProgressTakesPriority() {
        let active = Ghostty.Action.ProgressReport(state: .indeterminate, progress: nil)
        let determinate = Ghostty.Action.ProgressReport(state: .set, progress: 100)
        let paused = Ghostty.Action.ProgressReport(state: .pause, progress: 42)
        let failed = Ghostty.Action.ProgressReport(state: .error, progress: nil)
        let completed = Ghostty.Action.ProgressReport(state: .remove, progress: nil)

        #expect(status(progressReport: active) == .active)
        // A full progress bar can still represent finalization work. Only the
        // explicit remove event is treated as completion.
        #expect(status(progressReport: determinate) == .active)
        #expect(status(progressReport: paused) == .paused)
        #expect(status(progressReport: failed) == .failed)
        #expect(status(progressReport: completed) == .completed)
    }

    @Test func progressDisplayTimeoutDoesNotMeanCompleted() {
        let active = Ghostty.Action.ProgressReport(state: .indeterminate, progress: nil)
        let paused = Ghostty.Action.ProgressReport(state: .pause, progress: nil)

        let retainedActive = TerminalSessionActivityClassifier.retainedProgressReport(
            current: active,
            incoming: nil
        )
        let retainedPaused = TerminalSessionActivityClassifier.retainedProgressReport(
            current: paused,
            incoming: nil
        )

        #expect(retainedActive?.state == .indeterminate)
        #expect(retainedPaused?.state == .pause)
        #expect(status(tool: .codex, progressReport: retainedActive) == .active)
        #expect(status(tool: .claudeCode, progressReport: retainedPaused) == .paused)
    }

    @Test func recognizesCodexWorkingApprovalAndCompletionTitles() {
        #expect(status(tool: .codex, title: "⠙ ghostty-main") == .active)
        #expect(status(tool: .codex, title: "Thinking") == .active)
        #expect(
            status(tool: .codex, title: "[ ! ] Action Required | ghostty-main") == .paused
        )
        #expect(
            status(tool: .codex, title: "[ . ] Action Required | ghostty-main") == .paused
        )
        #expect(
            status(tool: .codex, title: "ghostty-main", previous: .active) == .completed
        )
        #expect(status(tool: .codex, title: "ghostty-main") == .ready)
    }

    @Test func recognizesClaudeWorkingQuestionsAndCompletion() {
        #expect(status(tool: .claudeCode, title: "⠸ Claude Code") == .active)
        #expect(status(tool: .claudeCode, title: "✳ Claude Code") == .ready)
        #expect(
            status(
                tool: .claudeCode,
                title: "✳ Claude Code",
                visibleContents: "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
            ) == .paused
        )
        #expect(
            status(
                tool: .claudeCode,
                title: "⠸ Claude Code",
                visibleContents: "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
            ) == .active
        )
        #expect(
            status(
                tool: .claudeCode,
                title: "✳ Claude Code",
                previous: .active
            ) == .completed
        )
    }

    @Test func doesNotInferAgentActivityForOrdinaryTerminals() {
        #expect(status(tool: .terminal, title: "Working", previous: .active) == .ready)
        #expect(status(tool: .terminal, title: "⠙ build") == .ready)
    }

    private func status(
        tool: TerminalSessionTool = .terminal,
        title: String = "",
        progressReport: Ghostty.Action.ProgressReport? = nil,
        visibleContents: String = "",
        previous: TerminalSessionActivityStatus = .ready
    ) -> TerminalSessionActivityStatus {
        TerminalSessionActivityClassifier.status(
            tool: tool,
            dynamicTitle: title,
            progressReport: progressReport,
            visibleContents: visibleContents,
            previous: previous
        )
    }
}

struct TerminalSessionInstructionExtractorTests {
    @Test func extractsLatestCodexHistoryBlockAndCollapsesWrappedLines() {
        let screen = """

        › First instruction

        • Finished the earlier task.

        › Refactor the sidebar
          and keep the logo size unchanged

        • Working

        › unsent composer draft
        shortcuts
        """

        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .codex,
                visibleContents: screen
            ) == "Refactor the sidebar and keep the logo size unchanged"
        )
    }

    @Test func extractsClaudeHistoryAndIgnoresPermissionPicker() {
        let screen = """

        ❯ Add a compact session summary

        ⏺ I will update the layout.

        Claude needs your permission
        ❯ 1. Yes
          2. No

        """

        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .claudeCode,
                visibleContents: screen
            ) == "Add a compact session summary"
        )
    }

    @Test func acceptsRecentAndChoiceLikeInstructionsOutsidePickers() {
        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .codex,
                visibleContents: "\n› quick task\n\n• Done\n"
            ) == "quick task"
        )
        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .codex,
                visibleContents: "\n› Yes\n\n• Working\n"
            ) == "Yes"
        )
        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .codex,
                visibleContents: "\n› 1. Refactor the sidebar\n\n• Working\n"
            ) == "1. Refactor the sidebar"
        )
        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .claudeCode,
                visibleContents: "\n❯ [x] keep the icon size\n\n⏺ Working\n"
            ) == "[x] keep the icon size"
        )
    }

    @Test func rejectsIncompleteHistoryPickerAndOrdinaryTerminalText() {
        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .codex,
                visibleContents: "\n› draft without a completed history boundary"
            ) == nil
        )
        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .claudeCode,
                visibleContents: "\nClaude needs your permission\n❯ 1. Yes\n  2. No\n\nEsc to cancel"
            ) == nil
        )
        #expect(
            TerminalSessionInstructionExtractor.lastInstruction(
                tool: .terminal,
                visibleContents: "\n> make test\n\n"
            ) == nil
        )
    }
}
