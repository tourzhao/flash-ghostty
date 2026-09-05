import Combine
import Foundation
import Testing
@testable import Ghostty

@Suite @MainActor
struct TerminalSessionProcessAttributionTests {
    @Test(arguments: ["codex", "claude"])
    func fastFirstRoundSurvivesDelayedProcessDiscovery(process: String) {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.startNewProcess()
        fixture.completeRound()
        fixture.source.progress = nil
        #expect(fixture.resolver.requests.map(\.pid) == [100, 200])
        #expect(fixture.tracker.count == 0)

        fixture.time = 3
        fixture.resolve(1, as: process)
        #expect(fixture.tracker.count == 1)
        #expect(fixture.monitor.activityStatus == .completed)
        #expect(fixture.monitor.activitySnapshot.observedAt == 1.5)
        #expect(fixture.counts == [1])
    }

    @Test func titleOnlyCodexRoundIsNotLost() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.time = 0.2
        fixture.source.pid = 200
        fixture.source.title = "Working"
        fixture.time = 1.5
        fixture.source.title = "Codex — finished"
        fixture.time = 3
        fixture.resolve(1, as: "codex")
        #expect(fixture.tracker.count == 1)
        #expect(fixture.monitor.activityStatus == .completed)
    }

    @Test(arguments: [true, false])
    func staleSpinnerCannotUndoAnExplicitCompletion(lookupIsDelayed: Bool) {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: lookupIsDelayed ? "zsh" : "codex")
        if lookupIsDelayed {
            fixture.startNewProcess()
        } else {
            fixture.source.title = "Working"
            fixture.source.progress = .init(state: .indeterminate, progress: nil)
        }
        fixture.time = 1.5
        fixture.source.progress = .init(state: .remove, progress: nil)
        fixture.time = 3
        if lookupIsDelayed { fixture.resolve(1, as: "codex") }
        fixture.tracker.advance()
        #expect(fixture.monitor.activityStatus == .completed)
        #expect(fixture.tracker.count == 1)
        fixture.monitor.refresh()
        #expect(fixture.monitor.activityStatus == .completed)
        #expect(fixture.tracker.count == 1)
        fixture.source.title = "Thinking"
        #expect(fixture.monitor.activityStatus == .active)
        #expect(fixture.tracker.count == 0)
    }

    @Test(arguments: ["zsh", "vim", "node"])
    func ordinaryProcessProgressNeverBecomesAnAgentReminder(process: String) {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "codex")
        fixture.source.progress = .init(state: .indeterminate, progress: nil)
        fixture.time = 1
        fixture.source.pid = 200
        fixture.source.title = "ordinary task"
        fixture.source.progress = .init(state: .pause, progress: nil)
        #expect(fixture.tracker.count == 0)
        fixture.resolve(1, as: process)
        #expect(fixture.tracker.count == 0)
        #expect(fixture.monitor.tool == .terminal)
        #expect(fixture.counts.isEmpty)
    }

    @Test(arguments: [true, false])
    func alreadyViewedCompletionIsNotResurrected(initiallyViewed: Bool) {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.viewed = initiallyViewed
        fixture.tracker.refreshVisibility()
        fixture.startNewProcess()
        fixture.completeRound()
        if !initiallyViewed {
            fixture.time = 1.6
            fixture.viewed = true
            fixture.tracker.refreshVisibility()
        }
        fixture.time = 2
        fixture.viewed = false
        fixture.tracker.refreshVisibility()
        fixture.time = 3
        fixture.resolve(1, as: "codex")
        #expect(fixture.tracker.count == 0)
        #expect(fixture.counts.isEmpty)
    }

    @Test func viewingBeforeCompletionDoesNotConsumeALaterRound() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.viewed = true
        fixture.tracker.refreshVisibility()
        fixture.startNewProcess()
        fixture.time = 0.5
        fixture.viewed = false
        fixture.tracker.refreshVisibility()
        fixture.completeRound()
        fixture.time = 3
        fixture.resolve(1, as: "codex")
        #expect(fixture.tracker.count == 1)
    }

    @Test func pidChangeRejectsOldResultAndCoalescesTheNewLookup() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        // The initial shell lookup is deliberately still pending.
        fixture.startNewProcess()
        fixture.completeRound()
        #expect(fixture.resolver.requests.map(\.pid) == [100])
        fixture.resolve(0, as: "zsh")
        #expect(fixture.resolver.requests.map(\.pid) == [100, 200])
        fixture.source.pid = 300
        fixture.source.title = "editor"
        fixture.source.progress = .init(state: .pause, progress: nil)
        fixture.resolve(1, as: "codex")
        #expect(fixture.resolver.requests.map(\.pid) == [100, 200, 300])
        #expect(fixture.tracker.count == 0)
        fixture.resolve(2, as: "vim")
        #expect(fixture.tracker.count == 0)
        #expect(fixture.counts.isEmpty)
    }

    @Test func bindingChangeRejectsOldEventsAndAttributionResults() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.startNewProcess()
        fixture.completeRound()
        let replacement = Source()
        replacement.pid = 300
        fixture.monitor.bindMetadataSource(
            to: replacement, preserving: nil, contains: { $0 === replacement }, titleDidChange: { _, _ in }
        )
        fixture.resolve(0, as: "codex")
        fixture.source.progress = .init(state: .pause, progress: nil)
        #expect(fixture.monitor.activityStatus == .ready)
        #expect(fixture.tracker.count == 0)
        #expect(fixture.resolver.requests.map(\.pid) == [100, 300])
        fixture.resolve(1, as: "zsh")
        #expect(fixture.tracker.count == 0)
    }

    @Test func stoppedSourceCannotReplayItsPendingCompletion() {
        let fixture = Fixture()
        fixture.resolve(0, as: "zsh")
        fixture.startNewProcess()
        fixture.completeRound()
        fixture.tracker.stop()
        fixture.time = 3
        fixture.resolve(1, as: "codex")
        #expect(fixture.tracker.count == 0)
        #expect(fixture.counts.isEmpty)
        #expect(!fixture.monitor.requiresPeriodicRefresh)
    }

    @Test func cachedBootstrapProgressDoesNotBelongToAnUnresolvedProcess() {
        let fixture = Fixture(initialProgress: .init(state: .pause, progress: nil))
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "codex")
        #expect(fixture.monitor.activityStatus == .ready)
        #expect(fixture.tracker.count == 0)
    }

    @Test(arguments: [true, false])
    func bootstrapProgressIsAcceptedOnlyForItsRecordedProcess(matchesPID: Bool) {
        let fixture = Fixture(
            initialProgress: .init(state: .indeterminate, progress: nil),
            progressPID: matchesPID ? 100 : 999
        )
        defer { fixture.tracker.stop() }
        fixture.source.progress = .init(state: .remove, progress: nil)
        fixture.time = 3
        fixture.resolve(0, as: "codex")
        #expect(fixture.tracker.count == (matchesPID ? 1 : 0))
    }

    @Test func isolatedCompletionAndExpiredProgressCannotInventARound() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.source.pid = 200
        fixture.source.title = "Codex — idle"
        fixture.source.progress = .init(state: .remove, progress: nil)
        fixture.source.progress = nil
        fixture.time = 3
        fixture.resolve(1, as: "codex")
        #expect(fixture.tracker.count == 0)
        #expect(fixture.counts.isEmpty)
    }

    @Test func pendingApprovalThatResumedDoesNotFlashAnOldReminder() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.startNewProcess()
        fixture.source.progress = .init(state: .pause, progress: nil)
        fixture.source.progress = .init(state: .indeterminate, progress: nil)
        fixture.source.progress = nil
        fixture.time = 3
        fixture.resolve(1, as: "codex")
        #expect(fixture.monitor.activityStatus == .active)
        #expect(fixture.counts.isEmpty)
    }

    @Test func sameProviderSubprocessPreservesAnAlreadyObservedRound() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "codex")
        fixture.source.progress = .init(state: .indeterminate, progress: nil)
        fixture.source.pid = 200
        fixture.time = 1
        fixture.source.title = "Codex — finished"
        fixture.source.progress = .init(state: .remove, progress: nil)
        fixture.time = 3
        fixture.resolve(1, as: "codex")
        #expect(fixture.tracker.count == 1)
    }

    @Test func transientLookupFailureRetainsBoundedEvidenceForRetry() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.startNewProcess()
        fixture.completeRound()
        fixture.resolve(1, as: nil)
        #expect(fixture.tracker.count == 0)
        fixture.time = 3
        fixture.monitor.refresh()
        fixture.resolve(2, as: "codex")
        #expect(fixture.tracker.count == 1)
    }

    @Test(arguments: [true, false])
    func missingPIDPreservesEvidenceOnlyForTheSameProcess(recoversSameProcess: Bool) {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "zsh")
        fixture.startNewProcess()
        fixture.completeRound()
        fixture.source.pid = nil
        fixture.source.title = "unattributable title"
        fixture.source.progress = .init(state: .pause, progress: nil)
        fixture.resolve(1, as: "codex")
        #expect(fixture.tracker.count == 0)
        #expect(fixture.resolver.requests.count == 2)

        fixture.time = 3
        fixture.source.pid = recoversSameProcess ? 200 : 300
        fixture.monitor.refresh()
        fixture.resolve(2, as: "codex")
        #expect(fixture.tracker.count == (recoversSameProcess ? 1 : 0))
        #expect(fixture.monitor.activityStatus != .paused)
    }

    @Test func missingPIDDoesNotMisattributeProgressToThePreviouslyKnownAgent() {
        let fixture = Fixture()
        defer { fixture.tracker.stop() }
        fixture.resolve(0, as: "codex")
        fixture.source.pid = nil
        fixture.source.progress = .init(state: .pause, progress: nil)
        fixture.monitor.refresh()
        #expect(fixture.monitor.activityStatus == .ready)
        #expect(fixture.counts.isEmpty)

        fixture.source.pid = 100
        fixture.source.progress = .init(state: .remove, progress: nil)
        fixture.tracker.advance()
        #expect(fixture.counts.isEmpty)
    }

    @MainActor private final class Resolver {
        struct Request {
            let pid: Int32
            let completion: @MainActor @Sendable (String?) -> Void
        }
        var requests: [Request] = []
        func lookup(_ pid: Int32, completion: @escaping @MainActor @Sendable (String?) -> Void) {
            requests.append(Request(pid: pid, completion: completion))
        }
    }

    @MainActor private final class Fixture {
        let source = Source()
        let resolver = Resolver()
        var time: TimeInterval = 0
        var viewed = false
        var counts: [Int] = []
        lazy var monitor = TerminalSessionMetadataMonitor(processLookup: { [resolver] pid, completion in
            resolver.lookup(pid, completion: completion)
        }, now: { [weak self] in self?.time ?? 0 })
        lazy var tracker = SessionAttentionTracker(
            makeSource: { [weak self] _ in self?.monitor }, isViewed: { [weak self] _ in self?.viewed == true },
            countDidChange: { [weak self] in self?.counts.append($0) }, now: { [weak self] in self?.time ?? 0 },
            automaticallySchedule: false
        )

        init(initialProgress: Ghostty.Action.ProgressReport? = nil, progressPID: Int32? = nil) {
            source.progress = initialProgress
            source.sessionMetadataProgressProcessID = progressPID
            monitor.bindMetadataSource(
                to: source, preserving: nil, contains: { [source] in $0 === source }, titleDidChange: { _, _ in }
            )
            tracker.reconcile(owners: [source.id: UUID()])
        }

        func resolve(_ index: Int, as name: String?) {
            guard resolver.requests.indices.contains(index) else {
                Issue.record("Missing process lookup \(index)")
                return
            }
            resolver.requests[index].completion(name)
        }

        func startNewProcess() {
            time = 0.2
            source.pid = 200
            source.title = "Working"
            source.progress = .init(state: .indeterminate, progress: nil)
        }

        func completeRound() {
            time = 1.5
            source.title = "Codex — finished"
            source.progress = .init(state: .remove, progress: nil)
        }
    }

    @MainActor private final class Source: TerminalSessionMetadataBindingSource {
        let id = UUID()
        var pid: Int32? = 100
        @Published var title = "shell"
        @Published var progress: Ghostty.Action.ProgressReport?
        @Published var bell = false
        @Published var directory: String?
        var sessionMetadataSurface: Ghostty.SurfaceView? { nil }
        var sessionMetadataSurfaceID: UUID? { id }
        var sessionMetadataForegroundPID: Int32? { pid }
        var sessionMetadataProgressProcessID: Int32?
        var sessionMetadataTitlePublisher: AnyPublisher<String, Never> { $title.eraseToAnyPublisher() }
        var sessionMetadataProgressPublisher: AnyPublisher<Ghostty.Action.ProgressReport?, Never> {
            $progress.eraseToAnyPublisher()
        }
        var sessionMetadataBellPublisher: AnyPublisher<Bool, Never> { $bell.eraseToAnyPublisher() }
        var sessionMetadataWorkingDirectoryPublisher: AnyPublisher<String?, Never> { $directory.eraseToAnyPublisher() }
    }
}
