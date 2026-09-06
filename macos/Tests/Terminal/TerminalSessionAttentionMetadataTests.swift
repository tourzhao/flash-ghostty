import Combine
import Foundation
import Testing
@testable import Ghostty

struct SessionAttentionMetadataPollingTests {
    @Test func attentionKeepsHiddenSessionsAtBackgroundCadence() {
        for isSelected in [false, true] {
            #expect(
                SessionMetadataPollingMode.resolve(
                    sidebarIsVisible: false,
                    sessionIsSelected: isSelected
                ) == .suspended
            )
            #expect(
                SessionMetadataPollingMode.resolve(
                    sidebarIsVisible: false,
                    sessionIsSelected: isSelected,
                    attentionIsEnabled: true
                ) == .background
            )
        }

        #expect(
            SessionMetadataPollingMode.resolve(
                sidebarIsVisible: true,
                sessionIsSelected: true,
                attentionIsEnabled: true
            ) == .selected
        )
        #expect(
            SessionMetadataPollingMode.resolve(
                sidebarIsVisible: true,
                sessionIsSelected: false,
                attentionIsEnabled: true
            ) == .background
        )
    }

    @Test func attentionDoesNotIncreaseTheBackgroundRefreshRate() {
        let mode = SessionMetadataPollingMode.resolve(
            sidebarIsVisible: false,
            sessionIsSelected: false,
            attentionIsEnabled: true
        )
        var throttle = SessionMetadataRefreshThrottle(mode: .suspended)
        let becameBackground = throttle.update(mode: mode)
        #expect(becameBackground)

        for _ in 0..<2 {
            for _ in 1..<SessionMetadataRefreshThrottle.backgroundIntervalTicks {
                let shouldRefresh = throttle.consumeTick()
                #expect(!shouldRefresh)
            }
            let shouldRefresh = throttle.consumeTick()
            #expect(shouldRefresh)
        }

        let becameSuspended = throttle.update(mode: .suspended)
        let shouldRefreshWhileSuspended = throttle.consumeTick()
        #expect(!becameSuspended)
        #expect(!shouldRefreshWhileSuspended)
    }
}

@MainActor
struct SessionAttentionMetadataSnapshotTests {
    @Test func bindingTransitionsPublishCoherentProviderAndActivityPairs() {
        let first = AttentionMetadataBindingSourceProbe(title: "Codex — First")
        let second = AttentionMetadataBindingSourceProbe(title: "Claude Code")
        let monitor = TerminalSessionMetadataMonitor()
        var snapshots: [TerminalSessionActivitySnapshot] = []
        let observation = monitor.$activitySnapshot.sink { snapshots.append($0) }

        monitor.bindMetadataSource(
            to: first,
            preserving: nil,
            contains: { $0 === first },
            titleDidChange: { _, _ in }
        )
        first.progressReport = .init(state: .indeterminate, progress: nil)
        monitor.bindMetadataSource(
            to: second,
            preserving: nil,
            contains: { $0 === second },
            titleDidChange: { _, _ in }
        )
        second.progressReport = .init(state: .pause, progress: nil)
        first.progressReport = .init(state: .error, progress: nil)
        monitor.bindMetadataSource(
            to: nil,
            preserving: nil,
            contains: { _ in false },
            titleDidChange: { _, _ in }
        )

        #expect(snapshots == [
            .init(tool: .terminal, status: .ready),
            .init(tool: .codex, status: .ready),
            .init(tool: .codex, status: .active),
            .init(tool: .terminal, status: .ready),
            .init(tool: .claudeCode, status: .ready),
            .init(tool: .claudeCode, status: .paused),
            .init(tool: .terminal, status: .ready),
        ])
        withExtendedLifetime(observation) {}
    }

    @Test func providerChangesCannotReuseThePreviousProvidersProgress() {
        let source = AttentionMetadataBindingSourceProbe(title: "Codex — First")
        let monitor = TerminalSessionMetadataMonitor()
        monitor.bindMetadataSource(
            to: source,
            preserving: nil,
            contains: { $0 === source },
            titleDidChange: { _, _ in }
        )
        source.progressReport = .init(state: .pause, progress: nil)
        var snapshots: [TerminalSessionActivitySnapshot] = []
        let observation = monitor.$activitySnapshot.sink { snapshots.append($0) }

        source.title = "Claude Code"

        #expect(snapshots == [
            .init(tool: .codex, status: .paused),
            .init(tool: .claudeCode, status: .ready),
        ])
        withExtendedLifetime(observation) {}
    }

    @Test func duplicateAndExpiredReportsDoNotRepublishAttentionState() {
        let source = AttentionMetadataBindingSourceProbe(title: "Codex — First")
        let monitor = TerminalSessionMetadataMonitor()
        monitor.bindMetadataSource(
            to: source,
            preserving: nil,
            contains: { $0 === source },
            titleDidChange: { _, _ in }
        )
        var snapshots: [TerminalSessionActivitySnapshot] = []
        let observation = monitor.$activitySnapshot.sink { snapshots.append($0) }

        source.progressReport = .init(state: .indeterminate, progress: nil)
        source.progressReport = .init(state: .indeterminate, progress: nil)
        source.progressReport = nil
        source.progressReport = .init(state: .remove, progress: nil)
        source.progressReport = nil

        #expect(snapshots == [
            .init(tool: .codex, status: .ready),
            .init(tool: .codex, status: .active),
            .init(tool: .codex, status: .completed),
        ])
        monitor.stopMonitoring()
        source.progressReport = .init(state: .pause, progress: nil)
        #expect(monitor.activitySnapshot == .init(tool: .codex, status: .completed))
        #expect(!monitor.requiresPeriodicRefresh)
        withExtendedLifetime(observation) {}
    }

    @Test func enablingAttentionPreservesPeriodicRefreshWithoutASidebar() {
        let monitor = TerminalSessionMetadataMonitor()
        monitor.updateRefreshContext(sidebarIsVisible: false, sessionIsSelected: false)
        #expect(!monitor.requiresPeriodicRefresh)

        monitor.updateRefreshContext(
            sidebarIsVisible: false,
            sessionIsSelected: false,
            attentionIsEnabled: true
        )
        #expect(monitor.requiresPeriodicRefresh)

        monitor.updateRefreshContext(sidebarIsVisible: false, sessionIsSelected: false)
        #expect(!monitor.requiresPeriodicRefresh)
    }
}

@MainActor
private final class AttentionMetadataBindingSourceProbe: TerminalSessionMetadataBindingSource {
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
    var sessionMetadataProgressPublisher: AnyPublisher<Ghostty.Action.ProgressReport?, Never> {
        $progressReport.eraseToAnyPublisher()
    }
    var sessionMetadataWorkingDirectoryPublisher: AnyPublisher<String?, Never> {
        $workingDirectory.eraseToAnyPublisher()
    }

    init(title: String) {
        self.title = title
    }
}
