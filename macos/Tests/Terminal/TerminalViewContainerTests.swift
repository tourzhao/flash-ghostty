//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import Combine
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

@MainActor
@Suite
struct SessionMetadataObservationIsolationTests {
    @Test func metadataInvalidationDoesNotInvalidateTheTerminalController() {
        let app = Ghostty.App(configPath: "/dev/null")
        let controller = MetadataObservationProbeController(
            app,
            surfaceTree: .init()
        )
        var controllerChangeCount = 0
        var metadataChangeCount = 0
        let controllerObservation = controller.objectWillChange.sink {
            controllerChangeCount += 1
        }
        let metadataObservation = controller.sessionMetadata.objectWillChange.sink {
            metadataChangeCount += 1
        }

        controller.sessionMetadata.objectWillChange.send()

        #expect(metadataChangeCount == 1)
        #expect(controllerChangeCount == 0)
        withExtendedLifetime((controllerObservation, metadataObservation)) {}
    }
}

@MainActor
@Suite
struct TerminalSessionMetadataMonitorBindingTests {
    @Test
    func transientOrInvalidFocusKeepsTheContainedCurrentSource() {
        let first = SessionMetadataBindingSourceProbe(
            title: "First",
            workingDirectory: "/private/tmp/first"
        )
        let outside = SessionMetadataBindingSourceProbe(
            title: "Outside",
            workingDirectory: "/private/tmp/outside"
        )
        let monitor = TerminalSessionMetadataMonitor()
        var reportedTitles: [(String, Bool)] = []
        let contains: (any TerminalSessionMetadataBindingSource) -> Bool = {
            $0 === first
        }
        let titleDidChange: (String, Bool) -> Void = {
            reportedTitles.append(($0, $1))
        }

        monitor.bindMetadataSource(
            to: first,
            preserving: nil,
            contains: contains,
            titleDidChange: titleDidChange
        )
        #expect(monitor.dynamicTitle == "First")
        #expect(monitor.workingDirectory?.path == "/private/tmp/first")
        let initialReportCount = reportedTitles.count

        // SwiftUI can briefly report no focused split. The current source is
        // retained while it still belongs to the controller's logical tree.
        monitor.bindMetadataSource(
            to: nil,
            preserving: nil,
            contains: contains,
            titleDidChange: titleDidChange
        )
        monitor.bindMetadataSource(
            to: outside,
            preserving: nil,
            contains: contains,
            titleDidChange: titleDidChange
        )

        outside.title = "Ignored outside"
        outside.workingDirectory = "/private/tmp/ignored-outside"
        first.title = "First retained"
        first.workingDirectory = "/private/tmp/first-retained"
        #expect(monitor.dynamicTitle == "First retained")
        #expect(monitor.workingDirectory?.path == "/private/tmp/first-retained")
        #expect(reportedTitles.count == initialReportCount + 1)
    }

    @Test func containedPreviousSourceReplacesARemovedCurrentSource() {
        let removed = SessionMetadataBindingSourceProbe(
            title: "Removed",
            workingDirectory: "/private/tmp/removed"
        )
        let previous = SessionMetadataBindingSourceProbe(
            title: "Previous",
            workingDirectory: "/private/tmp/previous"
        )
        let monitor = TerminalSessionMetadataMonitor()
        var removedIsContained = true
        let contains: (any TerminalSessionMetadataBindingSource) -> Bool = {
            source in
            source === removed ? removedIsContained : source === previous
        }

        monitor.bindMetadataSource(
            to: removed,
            preserving: nil,
            contains: contains,
            titleDidChange: { _, _ in }
        )
        removedIsContained = false
        monitor.bindMetadataSource(
            to: nil,
            preserving: previous,
            contains: contains,
            titleDidChange: { _, _ in }
        )

        #expect(monitor.dynamicTitle == "Previous")
        #expect(monitor.workingDirectory?.path == "/private/tmp/previous")
        removed.title = "Stale removed"
        removed.workingDirectory = "/private/tmp/stale-removed"
        #expect(monitor.dynamicTitle == "Previous")
        #expect(monitor.workingDirectory?.path == "/private/tmp/previous")
    }

    @Test func rebindAndClearRejectEveryStalePublisher() {
        let first = SessionMetadataBindingSourceProbe(
            title: "Codex — First",
            workingDirectory: "/private/tmp/first"
        )
        let second = SessionMetadataBindingSourceProbe(
            title: "Codex — Second",
            workingDirectory: "/private/tmp/second"
        )
        let monitor = TerminalSessionMetadataMonitor()
        var sourcesAreContained = true
        var reportedTitles: [(String, Bool)] = []
        let contains: (any TerminalSessionMetadataBindingSource) -> Bool = {
            source in
            sourcesAreContained && (source === first || source === second)
        }
        let titleDidChange: (String, Bool) -> Void = {
            reportedTitles.append(($0, $1))
        }

        monitor.bindMetadataSource(
            to: first,
            preserving: nil,
            contains: contains,
            titleDidChange: titleDidChange
        )
        first.progressReport = .init(state: .indeterminate, progress: nil)
        first.bell = true
        #expect(monitor.activityStatus == .active)

        monitor.bindMetadataSource(
            to: second,
            preserving: first,
            contains: contains,
            titleDidChange: titleDidChange
        )
        second.progressReport = .init(state: .pause, progress: nil)
        #expect(monitor.dynamicTitle == "Codex — Second")
        #expect(monitor.workingDirectory?.path == "/private/tmp/second")
        #expect(monitor.activityStatus == .paused)
        let secondReportCount = reportedTitles.count

        // Rebinding must cancel every publisher owned by the old source.
        first.title = "Stale first"
        first.bell = false
        first.progressReport = .init(state: .error, progress: nil)
        first.workingDirectory = "/private/tmp/stale-first"
        #expect(monitor.dynamicTitle == "Codex — Second")
        #expect(monitor.workingDirectory?.path == "/private/tmp/second")
        #expect(monitor.activityStatus == .paused)
        #expect(reportedTitles.count == secondReportCount)

        second.title = "Codex — Second current"
        second.bell = true
        second.workingDirectory = "/private/tmp/second-current"
        #expect(monitor.dynamicTitle == "Codex — Second current")
        #expect(monitor.workingDirectory?.path == "/private/tmp/second-current")

        sourcesAreContained = false
        monitor.bindMetadataSource(
            to: nil,
            preserving: second,
            contains: contains,
            titleDidChange: titleDidChange
        )
        #expect(monitor.dynamicTitle.isEmpty)
        #expect(monitor.workingDirectory == nil)
        #expect(reportedTitles.last?.0 == "👻")
        #expect(reportedTitles.last?.1 == false)
        #expect(monitor.activityStatus == .ready)
        let clearedReportCount = reportedTitles.count

        second.title = "Stale second"
        second.bell = false
        second.progressReport = .init(state: .indeterminate, progress: nil)
        second.workingDirectory = "/private/tmp/stale-second"
        #expect(monitor.dynamicTitle.isEmpty)
        #expect(monitor.workingDirectory == nil)
        #expect(monitor.activityStatus == .ready)
        #expect(reportedTitles.count == clearedReportCount)
    }

    @Test func stopMonitoringUnbindsAndRejectsEveryPublisher() {
        var source: SessionMetadataBindingSourceProbe? =
            SessionMetadataBindingSourceProbe(
                title: "Codex — Before stop",
                workingDirectory: "/private/tmp/before-stop"
            )
        weak let weakSource = source
        let monitor = TerminalSessionMetadataMonitor()
        var reportedTitles: [(String, Bool)] = []

        monitor.bindMetadataSource(
            to: source,
            preserving: nil,
            contains: { _ in true },
            titleDidChange: { reportedTitles.append(($0, $1)) }
        )
        source?.progressReport = .init(state: .pause, progress: nil)
        source?.bell = true
        #expect(monitor.dynamicTitle == "Codex — Before stop")
        #expect(monitor.workingDirectory?.path == "/private/tmp/before-stop")
        #expect(monitor.activityStatus == .paused)

        monitor.stopMonitoring()
        let stoppedReportCount = reportedTitles.count

        source?.title = "Stale after stop"
        source?.bell = false
        source?.progressReport = .init(state: .error, progress: nil)
        source?.workingDirectory = "/private/tmp/stale-after-stop"
        #expect(monitor.dynamicTitle == "Codex — Before stop")
        #expect(monitor.workingDirectory?.path == "/private/tmp/before-stop")
        #expect(monitor.activityStatus == .paused)
        #expect(reportedTitles.count == stoppedReportCount)

        source = nil
        #expect(weakSource == nil)
    }
}

@MainActor
private final class SessionMetadataBindingSourceProbe:
    TerminalSessionMetadataBindingSource {
    @Published var title: String
    @Published var bell = false
    @Published var progressReport: Ghostty.Action.ProgressReport?
    @Published var workingDirectory: String?

    var sessionMetadataSurface: Ghostty.SurfaceView? { nil }
    var sessionMetadataTitlePublisher: AnyPublisher<String, Never> {
        $title.eraseToAnyPublisher()
    }
    var sessionMetadataBellPublisher: AnyPublisher<Bool, Never> {
        $bell.eraseToAnyPublisher()
    }
    var sessionMetadataProgressPublisher:
        AnyPublisher<Ghostty.Action.ProgressReport?, Never> {
        $progressReport.eraseToAnyPublisher()
    }
    var sessionMetadataWorkingDirectoryPublisher:
        AnyPublisher<String?, Never> {
        $workingDirectory.eraseToAnyPublisher()
    }

    init(title: String, workingDirectory: String?) {
        self.title = title
        self.workingDirectory = workingDirectory
    }
}

@MainActor
private final class MetadataObservationProbeController: BaseTerminalController {
    override var undoManager: ExpiringUndoManager? { nil }
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
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "✳ Claude Code",
                foregroundProcessName: "/Users/claude/projects/node"
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
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "",
                foregroundProcessName: "/Users/claude/projects/node"
            ) == .terminal
        )
        #expect(
            TerminalSessionTool.detect(
                fromDynamicTitle: "",
                foregroundProcessName: "/tmp/codex-worktree/bin/zsh"
            ) == .terminal
        )
    }
}

struct SessionMetadataRefreshThrottleTests {
    @Test func resolvesVisibilityAndSelectionToPollingModes() {
        #expect(
            SessionMetadataPollingMode.resolve(
                sidebarIsVisible: true,
                sessionIsSelected: true
            ) == .selected
        )
        #expect(
            SessionMetadataPollingMode.resolve(
                sidebarIsVisible: true,
                sessionIsSelected: false
            ) == .background
        )
        #expect(
            SessionMetadataPollingMode.resolve(
                sidebarIsVisible: false,
                sessionIsSelected: true
            ) == .suspended
        )
        #expect(SessionMetadataPollingMode.selected.allowsVisibleContentsReads)
        #expect(SessionMetadataPollingMode.background.allowsVisibleContentsReads)
        #expect(!SessionMetadataPollingMode.suspended.allowsVisibleContentsReads)
    }

    @Test func selectedBackgroundAndHiddenCadencesAreBounded() {
        var selected = SessionMetadataRefreshThrottle(mode: .selected)
        let firstSelectedTick = selected.consumeTick()
        let secondSelectedTick = selected.consumeTick()
        #expect(firstSelectedTick)
        #expect(secondSelectedTick)

        var background = SessionMetadataRefreshThrottle(mode: .background)
        for _ in 1..<SessionMetadataRefreshThrottle.backgroundIntervalTicks {
            let shouldRefresh = background.consumeTick()
            #expect(!shouldRefresh)
        }
        let backgroundRefresh = background.consumeTick()
        let nextBackgroundTick = background.consumeTick()
        #expect(backgroundRefresh)
        #expect(!nextBackgroundTick)

        var hidden = SessionMetadataRefreshThrottle(mode: .suspended)
        for _ in 0..<10 {
            let shouldRefresh = hidden.consumeTick()
            #expect(!shouldRefresh)
        }
    }

    @Test func becomingVisibleOrSelectedRequestsAnImmediateRefresh() {
        var throttle = SessionMetadataRefreshThrottle(mode: .suspended)
        let becameVisible = throttle.update(mode: .background)
        let unchangedBackground = throttle.update(mode: .background)
        let becameSelected = throttle.update(mode: .selected)
        let becameBackground = throttle.update(mode: .background)
        let becameHidden = throttle.update(mode: .suspended)
        let selectedAfterHidden = throttle.update(mode: .selected)

        #expect(becameVisible)
        #expect(!unchangedBackground)
        #expect(becameSelected)
        #expect(!becameBackground)
        #expect(!becameHidden)
        #expect(selectedAfterHidden)
    }
}

struct SessionProcessLookupRequestTests {
    @Test func acceptsOnlyTheBoundSurfaceGenerationAndCurrentProcess() {
        let surfaceID = UUID()
        let request = SessionProcessLookupRequest(
            generation: 4,
            surfaceID: surfaceID,
            processID: 101
        )

        #expect(request.matchesBinding(generation: 4, surfaceID: surfaceID))
        #expect(!request.matchesBinding(generation: 5, surfaceID: surfaceID))
        #expect(!request.matchesBinding(generation: 4, surfaceID: UUID()))
        #expect(request.matchesProcess(101))
        #expect(!request.matchesProcess(202))
        #expect(!request.matchesProcess(nil))

        #expect(
            request.disposition(
                currentGeneration: 4,
                currentSurfaceID: surfaceID,
                currentProcessID: 101
            ) == .accept
        )
        #expect(
            request.disposition(
                currentGeneration: 5,
                currentSurfaceID: surfaceID,
                currentProcessID: 101
            ) == .discard
        )
        #expect(
            request.disposition(
                currentGeneration: 4,
                currentSurfaceID: surfaceID,
                currentProcessID: 202
            ) == .retryCurrentProcess
        )
        #expect(
            request.disposition(
                currentGeneration: 4,
                currentSurfaceID: surfaceID,
                currentProcessID: nil
            ) == .retryCurrentProcess
        )
    }
}

struct SessionProcessLookupThrottleTests {
    @Test func stableProcessIsRevalidatedAtTheBoundedCadence() {
        var throttle = SessionProcessLookupThrottle()

        #expect(throttle.shouldLookup(processID: 101, now: 10))
        throttle.accept(processID: 101, now: 10)
        #expect(!throttle.shouldLookup(processID: 101, now: 12.99))
        #expect(throttle.shouldLookup(processID: 101, now: 13))
    }

    @Test func processChangesAndLifecycleResetBypassTheStableCadence() {
        var throttle = SessionProcessLookupThrottle()
        throttle.accept(processID: 101, now: 10)

        #expect(throttle.shouldLookup(processID: 202, now: 10.1))
        throttle.reset()
        #expect(throttle.shouldLookup(processID: 101, now: 10.1))
    }
}

struct SessionInstructionStoreTests {
    @Test func instructionsAreScopedToBothSurfaceAndProvider() {
        let firstSurface = UUID()
        let secondSurface = UUID()
        var store = SessionInstructionStore()

        store.store("codex task", surfaceID: firstSurface, tool: .codex)
        store.store("claude task", surfaceID: firstSurface, tool: .claudeCode)
        store.store("other surface", surfaceID: secondSurface, tool: .codex)
        store.store("shell input", surfaceID: firstSurface, tool: .terminal)

        #expect(
            store.instruction(surfaceID: firstSurface, tool: .codex) ==
                "codex task"
        )
        #expect(
            store.instruction(surfaceID: firstSurface, tool: .claudeCode) ==
                "claude task"
        )
        #expect(
            store.instruction(surfaceID: secondSurface, tool: .codex) ==
                "other surface"
        )
        #expect(store.instruction(surfaceID: firstSurface, tool: .terminal) == nil)
    }

    @Test func evictsTheLeastRecentlyUsedKeyAtCapacity() {
        let surfaceIDs = (0...SessionInstructionStore.capacity).map { _ in UUID() }
        var store = SessionInstructionStore()

        for index in 0..<SessionInstructionStore.capacity {
            store.store(
                "instruction \(index)",
                surfaceID: surfaceIDs[index],
                tool: .codex
            )
        }

        store.store(
            "updated",
            surfaceID: surfaceIDs[0],
            tool: .codex
        )
        store.store(
            "newest",
            surfaceID: surfaceIDs[SessionInstructionStore.capacity],
            tool: .claudeCode
        )

        #expect(store.count == SessionInstructionStore.capacity)
        #expect(
            store.instruction(surfaceID: surfaceIDs[0], tool: .codex) ==
                "updated"
        )
        #expect(store.instruction(surfaceID: surfaceIDs[1], tool: .codex) == nil)
        #expect(
            store.instruction(
                surfaceID: surfaceIDs[SessionInstructionStore.capacity],
                tool: .claudeCode
            ) == "newest"
        )
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

struct SessionContentsRefreshPolicyTests {
    @Test func defersReadsDuringScrollCooldown() {
        #expect(
            SessionContentsRefreshPolicy.decision(
                now: 10,
                lastScrollInput: 9.8,
                lastRefresh: 9.9,
                allowsSnapshotReuse: true
            ) == .deferUntilScrollingStops
        )
        #expect(
            SessionContentsRefreshPolicy.decision(
                now: 10.4,
                lastScrollInput: 10,
                lastRefresh: nil,
                allowsSnapshotReuse: true
            ) == .refreshSnapshot
        )
        #expect(
            SessionContentsRefreshPolicy.decision(
                now: 20,
                lastScrollInput: nil,
                lastRefresh: 19.9,
                allowsSnapshotReuse: true,
                defersSnapshotRefresh: true
            ) == .deferUntilScrollingStops
        )
    }

    @Test func reusesRecentSnapshotsAndRefreshesExpiredOnes() {
        #expect(
            SessionContentsRefreshPolicy.decision(
                now: 10,
                lastScrollInput: nil,
                lastRefresh: 8.5,
                allowsSnapshotReuse: true
            ) == .reuseSnapshot
        )
        #expect(
            SessionContentsRefreshPolicy.decision(
                now: 10,
                lastScrollInput: nil,
                lastRefresh: 8,
                allowsSnapshotReuse: true
            ) == .refreshSnapshot
        )
        #expect(
            SessionContentsRefreshPolicy.decision(
                now: 10,
                lastScrollInput: nil,
                lastRefresh: 9.5,
                allowsSnapshotReuse: false
            ) == .refreshSnapshot
        )
    }

    @Test func statusSnapshotsAreRequestedOnlyForClaudeFallback() {
        #expect(
            !SessionContentsRefreshPolicy.requiresSnapshot(
                forStatusFallback: true,
                contentIndependentStatus: .active
            )
        )
        #expect(
            SessionContentsRefreshPolicy.requiresSnapshot(
                forStatusFallback: true,
                contentIndependentStatus: nil
            )
        )
    }
}

struct SessionContentsAnalyzerTests {
    @Test func scrolledUpPermissionPromptCannotOverrideActiveBottomState() {
        let historicalViewport = TerminalSessionVisibleContentsAnalyzer.analyze(
            tool: .claudeCode,
            visibleContents: """

            ❯ earlier instruction

            Claude needs your permission
            ❯ 1. Yes
              2. No
            Esc to cancel
            """
        )
        let activeBottom = TerminalSessionVisibleContentsAnalyzer.analyze(
            tool: .claudeCode,
            visibleContents: """

            ❯ latest instruction

            ⏺ Finished the current turn.

            """
        )

        // The old viewport demonstrates the exact false-positive that a
        // scrolled-up surface used to produce. Sidebar classification receives
        // the active-bottom snapshot instead, independent of viewport scroll.
        #expect(historicalViewport.requiresUserInput)
        #expect(!activeBottom.requiresUserInput)
        #expect(activeBottom.lastInstruction == "latest instruction")
        #expect(
            TerminalSessionActivityClassifier.status(
                tool: .claudeCode,
                dynamicTitle: "✳ Claude Code",
                progressReport: nil,
                visibleContentsAnalysis: activeBottom,
                previous: .active
            ) == .completed
        )
    }

    @Test func extractsClaudePromptFactsOffTheMainActor() {
        let analysis = TerminalSessionVisibleContentsAnalyzer.analyze(
            tool: .claudeCode,
            visibleContents: """

            ❯ update the sidebar

            Claude needs your permission
            ❯ 1. Yes
              2. No
            Esc to cancel
            """
        )

        #expect(analysis.requiresUserInput)
        #expect(analysis.lastInstruction == "update the sidebar")
    }

    @Test func preParsedFactsPreserveProviderPrecedence() {
        let permissionPrompt = TerminalSessionVisibleContentsAnalysis(
            requiresUserInput: true,
            lastInstruction: nil
        )
        let spinnerStatus = TerminalSessionActivityClassifier.status(
            tool: .claudeCode,
            dynamicTitle: "⠸ Claude Code",
            progressReport: nil,
            visibleContentsAnalysis: permissionPrompt,
            previous: .completed
        )
        #expect(spinnerStatus == .active)

        let pausedStatus = TerminalSessionActivityClassifier.status(
            tool: .claudeCode,
            dynamicTitle: "✳ Claude Code",
            progressReport: nil,
            visibleContentsAnalysis: permissionPrompt,
            previous: .active
        )
        #expect(pausedStatus == .paused)

        let completed = Ghostty.Action.ProgressReport(state: .remove, progress: nil)
        let completedStatus = TerminalSessionActivityClassifier.status(
            tool: .claudeCode,
            dynamicTitle: "✳ Claude Code",
            progressReport: completed,
            visibleContentsAnalysis: permissionPrompt,
            previous: .active
        )
        #expect(completedStatus == .completed)
    }
}

struct DeferredInstructionCaptureStateTests {
    @Test func onlyMatchingReadConsumesPendingCapture() {
        var state = DeferredInstructionCaptureState()
        #expect(state.pendingID == nil)

        let captureID = state.markDeferred()
        #expect(state.isPending)
        #expect(state.markDeferred() == captureID)
        let consumedWrongID = state.consume(id: captureID &+ 1)
        #expect(!consumedWrongID)
        #expect(state.isPending)
        let consumedCapture = state.consume(id: captureID)
        #expect(consumedCapture)
        #expect(!state.isPending)
        let consumedTwice = state.consume(id: captureID)
        #expect(!consumedTwice)
    }

    @Test func scrollDefersButDoesNotDiscardPendingCapture() {
        var state = DeferredInstructionCaptureState()
        let captureID = state.markDeferred()

        #expect(
            !InstructionCaptureRetryPolicy.shouldRetry(
                hasPendingCapture: state.isPending,
                defersVisibleContentsRefresh: true
            )
        )
        #expect(state.pendingID == captureID)
        #expect(
            InstructionCaptureRetryPolicy.shouldRetry(
                hasPendingCapture: state.isPending,
                defersVisibleContentsRefresh: false
            )
        )
    }
}

struct SessionContentsRequestStateTests {
    @Test func freshStatusRequestDuringReadCreatesOneFollowUp() {
        var state = SessionContentsRequestState(minimumInterval: 0)
        guard case .start(let oldRequest) = state.request(.status) else {
            Issue.record("Expected the old status read to start")
            return
        }

        #expect(
            state.request(
                .status,
                requiresFreshResultIfBusy: true
            ) == .coalesced
        )
        #expect(
            state.request(
                .status,
                requiresFreshResultIfBusy: true
            ) == .coalesced
        )
        let completion = state.complete(requestID: oldRequest.id)
        #expect(completion.followUpPurpose == .status)

        guard case .start(let followUp) = state.request(.status) else {
            Issue.record("Expected exactly one fresh status follow-up")
            return
        }
        #expect(state.complete(requestID: followUp.id).followUpPurpose == nil)
    }

    @Test func freshCaptureDuringStatusReadCreatesOneFollowUp() {
        var state = SessionContentsRequestState(minimumInterval: 0)
        guard case .start(let statusRequest) = state.request(.status) else {
            Issue.record("Expected the first status read to start")
            return
        }

        #expect(state.request(.instructionCapture(1)) == .coalesced)
        #expect(state.request(.instructionCapture(1)) == .coalesced)
        let statusCompletion = state.complete(requestID: statusRequest.id)
        #expect(statusCompletion.acceptsResult)
        #expect(statusCompletion.fulfilledCaptureID == nil)
        #expect(statusCompletion.requiresFollowUp)
        #expect(statusCompletion.followUpPurpose == .instructionCapture(1))

        guard case .start(let captureRequest) =
                state.request(.instructionCapture(1)) else {
            Issue.record("Expected one capture follow-up")
            return
        }
        let captureCompletion = state.complete(requestID: captureRequest.id)
        #expect(captureCompletion.fulfilledCaptureID == 1)
        #expect(!captureCompletion.requiresFollowUp)
    }

    @Test func oldCaptureCannotConsumeNewPendingCapture() {
        var state = SessionContentsRequestState(minimumInterval: 0)
        guard case .start(let oldRequest) =
                state.request(.instructionCapture(1)) else {
            Issue.record("Expected the old capture to start")
            return
        }

        #expect(state.request(.instructionCapture(2)) == .coalesced)
        let oldCompletion = state.complete(requestID: oldRequest.id)
        #expect(oldCompletion.fulfilledCaptureID == nil)
        #expect(oldCompletion.requiresFollowUp)
        #expect(oldCompletion.followUpPurpose == .instructionCapture(2))

        guard case .start(let newRequest) =
                state.request(.instructionCapture(2)) else {
            Issue.record("Expected the newer capture to start")
            return
        }
        #expect(!state.complete(requestID: oldRequest.id).acceptsResult)
        #expect(state.complete(requestID: newRequest.id).fulfilledCaptureID == 2)
    }

    @Test func repeatedSameCaptureSharesItsInFlightRead() {
        var state = SessionContentsRequestState(minimumInterval: 0)
        guard case .start(let request) =
                state.request(.instructionCapture(7)) else {
            Issue.record("Expected the capture to start")
            return
        }

        #expect(state.request(.instructionCapture(7)) == .coalesced)
        let completion = state.complete(requestID: request.id)
        #expect(completion.fulfilledCaptureID == 7)
        #expect(!completion.requiresFollowUp)
    }

    @Test func hundredEventBurstStartsOneReadAndOneTrailingRead() {
        var state = SessionContentsRequestState(minimumInterval: 0.5)
        var rendererReadCount = 0

        guard case .start(let activeRequest) = state.request(
            .status,
            now: 10,
            requiresFreshResultIfBusy: true
        ) else {
            Issue.record("Expected the burst's leading read to start")
            return
        }
        rendererReadCount += 1

        for _ in 1..<100 {
            #expect(
                state.request(
                    .status,
                    now: 10.01,
                    requiresFreshResultIfBusy: true
                ) == .coalesced
            )
        }
        #expect(state.isInFlight)
        #expect(!state.hasScheduledTrailingRefresh)

        let completion = state.complete(requestID: activeRequest.id, now: 10.1)
        guard let trailingPurpose = completion.followUpPurpose,
              case .scheduleTrailing(let trailingRefresh) = state.request(
                trailingPurpose,
                now: 10.1
              ) else {
            Issue.record("Expected one rate-limited trailing read")
            return
        }
        #expect(!state.isInFlight)
        #expect(state.hasScheduledTrailingRefresh)
        #expect(abs(trailingRefresh.delay - 0.5) < 0.000_001)

        guard let trailingRequest = state.beginTrailingRefresh(
            id: trailingRefresh.id,
            now: 10.600_001
        ) else {
            Issue.record("Expected the newest trailing token to start")
            return
        }
        rendererReadCount += 1
        #expect(state.isInFlight)
        #expect(!state.hasScheduledTrailingRefresh)
        #expect(rendererReadCount == 2)
        #expect(
            state.beginTrailingRefresh(
                id: trailingRefresh.id,
                now: 10.600_001
            ) == nil
        )
        #expect(
            state.complete(requestID: trailingRequest.id, now: 10.7)
                .followUpPurpose == nil
        )
    }

    @Test func replacementAndSuspensionInvalidateOlderTrailingTokens() {
        var state = SessionContentsRequestState(minimumInterval: 0.5)
        guard case .start(let request) = state.request(.status, now: 20) else {
            Issue.record("Expected the leading read to start")
            return
        }
        _ = state.complete(requestID: request.id, now: 20.1)

        guard case .scheduleTrailing(let first) = state.request(
            .status,
            now: 20.2
        ), case .scheduleTrailing(let replacement) = state.request(
            .instructionCapture(7),
            now: 20.25
        ) else {
            Issue.record("Expected a replaceable trailing refresh")
            return
        }
        #expect(first.id != replacement.id)

        var replacementProbe = state
        #expect(
            replacementProbe.beginTrailingRefresh(
                id: first.id,
                now: 20.600_001
            ) == nil
        )
        #expect(
            replacementProbe.beginTrailingRefresh(
                id: replacement.id,
                now: 20.600_001
            )?.purpose == .instructionCapture(7)
        )

        // `invalidateVisibleContentsReads` calls this reset when the monitor is
        // suspended, in addition to cancelling its DispatchWorkItem.
        state.reset()
        #expect(!state.hasScheduledTrailingRefresh)
        #expect(
            state.beginTrailingRefresh(
                id: replacement.id,
                now: 20.600_001
            ) == nil
        )
    }
}

struct ActivityWithoutSessionContentsTests {
    @Test func structuredProgressRemainsDefinitiveWhileScrolling() {
        let paused = Ghostty.Action.ProgressReport(state: .pause, progress: nil)
        #expect(
            TerminalSessionActivityClassifier.statusWithoutVisibleContentsIfDefinitive(
                tool: .claudeCode,
                dynamicTitle: "✳ Claude Code",
                progressReport: paused,
                previous: .active
            ) == .paused
        )
        #expect(
            TerminalSessionActivityClassifier.statusWithoutVisibleContentsIfDefinitive(
                tool: .claudeCode,
                dynamicTitle: "⠸ Claude Code",
                progressReport: nil,
                previous: .completed
            ) == .active
        )
        #expect(
            TerminalSessionActivityClassifier.statusWithoutVisibleContentsIfDefinitive(
                tool: .claudeCode,
                dynamicTitle: "✳ Claude Code",
                progressReport: nil,
                previous: .active
            ) == nil
        )
    }

    @Test func onlyLatchedStructuredReportsNeedClaudeFallbackText() {
        let active = Ghostty.Action.ProgressReport(state: .indeterminate, progress: nil)
        let paused = Ghostty.Action.ProgressReport(state: .pause, progress: nil)
        let completed = Ghostty.Action.ProgressReport(state: .remove, progress: nil)
        let failed = Ghostty.Action.ProgressReport(state: .error, progress: nil)

        #expect(
            !TerminalSessionActivityClassifier.requiresVisibleContentsFallback(
                tool: .claudeCode,
                progressReport: active
            )
        )
        #expect(
            !TerminalSessionActivityClassifier.requiresVisibleContentsFallback(
                tool: .claudeCode,
                progressReport: paused
            )
        )
        #expect(
            TerminalSessionActivityClassifier.requiresVisibleContentsFallback(
                tool: .claudeCode,
                progressReport: completed
            )
        )
        #expect(
            TerminalSessionActivityClassifier.requiresVisibleContentsFallback(
                tool: .claudeCode,
                progressReport: failed
            )
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
