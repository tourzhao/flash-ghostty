import Combine
import Foundation
import Testing
@testable import Ghostty

@Suite @MainActor
struct SessionAttentionTrackerTests {
    private final class Source: SessionAttentionSource {
        let subject = CurrentValueSubject<TerminalSessionActivitySnapshot, Never>(
            .init(tool: .codex, status: .ready)
        )
        var starts = 0
        var stops = 0
        var attentionUpdates: AnyPublisher<TerminalSessionActivitySnapshot, Never> {
            subject.eraseToAnyPublisher()
        }
        func startAttentionMonitoring() { starts += 1 }
        func stopAttentionMonitoring() {
            stops += 1
            // A synchronous callback during teardown must not restore state.
            send(.paused)
        }
        func send(_ status: TerminalSessionActivityStatus, observedAt: TimeInterval? = nil) {
            subject.send(.init(tool: .codex, status: status, observedAt: observedAt))
        }
    }

    @Test func closedSourcesCannotRestoreCountAndStopIsIdempotent() {
        let id = UUID()
        let source = Source()
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in false },
            countDidChange: { counts.append($0) }, automaticallySchedule: false
        )
        tracker.reconcile(owners: [id: UUID()])
        source.send(.paused)
        #expect(tracker.count == 1)
        tracker.stop()
        source.send(.paused)
        tracker.stop()
        #expect(counts == [1, 0])
        #expect(source.starts == 1)
        #expect(source.stops == 1)
    }

    @Test func unchangedOwnershipAndMovesReuseTheSubscription() {
        let id = UUID()
        let session = UUID()
        let source = Source()
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in false },
            countDidChange: { _ in }, automaticallySchedule: false
        )
        tracker.reconcile(owners: [id: session])
        source.send(.paused)
        tracker.reconcile(owners: [id: session])
        tracker.reconcile(owners: [id: UUID()])
        #expect(tracker.count == 1)
        #expect(source.starts == 1)
        #expect(source.stops == 0)
        tracker.stop()
    }

    @Test func replacedSourceWithSameIDRejectsOldEvents() {
        let id = UUID()
        let first = Source()
        let second = Source()
        var current = first
        let tracker = SessionAttentionTracker(
            makeSource: { _ in current }, isViewed: { _ in false },
            countDidChange: { _ in }, automaticallySchedule: false
        )
        tracker.reconcile(owners: [id: UUID()])
        first.send(.paused)
        tracker.reconcile(owners: [:])
        current = second
        tracker.reconcile(owners: [id: UUID()])
        first.send(.paused)
        #expect(tracker.count == 0)
        second.send(.paused)
        #expect(tracker.count == 1)
        tracker.stop()
    }

    @Test func deadlineRechecksVisibilityWithoutAcknowledgingApproval() {
        let id = UUID()
        let source = Source()
        var now: TimeInterval = 10
        var viewed = false
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in viewed },
            countDidChange: { counts.append($0) }, now: { now }, automaticallySchedule: false
        )
        tracker.reconcile(owners: [id: UUID()])
        source.send(.active)
        source.send(.completed)
        #expect(tracker.count == 0)
        viewed = true
        now = 12
        tracker.advance()
        #expect(tracker.count == 0)
        #expect(counts.isEmpty)
        source.send(.paused)
        tracker.refreshVisibility()
        #expect(tracker.count == 1)
        source.send(.active)
        #expect(tracker.count == 0)
        tracker.stop()
    }

    @Test func multiplePanesOnlyAcknowledgeTheViewedCompletion() {
        let firstID = UUID()
        let secondID = UUID()
        let session = UUID()
        let first = Source()
        let second = Source()
        var viewed: UUID?
        var now: TimeInterval = 0
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { $0 == firstID ? first : second },
            isViewed: { $0 == viewed }, countDidChange: { counts.append($0) },
            now: { now }, automaticallySchedule: false
        )
        tracker.reconcile(owners: [firstID: session, secondID: session])
        first.send(.active)
        second.send(.active)
        first.send(.completed)
        second.send(.completed)
        now = 2
        tracker.advance()
        #expect(tracker.count == 1)
        viewed = firstID
        tracker.refreshVisibility()
        #expect(tracker.count == 1)
        viewed = secondID
        tracker.refreshVisibility()
        #expect(tracker.count == 0)
        second.send(.completed)
        #expect(counts == [1, 0])
        tracker.stop()
    }

    private enum DelayedCompletionViewing: CaseIterable {
        case completedWhileViewed
        case viewedAfterCompletion
        case alwaysInBackground
        case viewedBeforeCompletion

        var acknowledgesCompletion: Bool {
            self == .completedWhileViewed || self == .viewedAfterCompletion
        }
    }

    @Test(arguments: DelayedCompletionViewing.allCases)
    private func delayedCompletionUsesOriginalViewingHistory(viewing: DelayedCompletionViewing) {
        let id = UUID()
        let source = Source()
        var now: TimeInterval = 0
        var viewed = viewing == .completedWhileViewed || viewing == .viewedBeforeCompletion
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in viewed },
            countDidChange: { counts.append($0) }, now: { now }, automaticallySchedule: false
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [id: UUID()])

        if viewing == .viewedBeforeCompletion {
            now = 1
            viewed = false
            tracker.refreshVisibility()
        }
        // The round completes at time 2, while provider discovery is pending.
        if viewing == .viewedAfterCompletion {
            now = 3
            viewed = true
            tracker.refreshVisibility()
        }
        now = 4
        viewed = false
        tracker.refreshVisibility()

        // Delivery happens after the one-second completion deadline.
        now = 10
        source.send(.active, observedAt: 1.5)
        source.send(.completed, observedAt: 2)
        source.send(.completed, observedAt: 2)

        #expect(tracker.count == (viewing.acknowledgesCompletion ? 0 : 1))
        #expect(counts == (viewing.acknowledgesCompletion ? [] : [1]))
    }

    @Test func delayedCompletionKeepsItsOriginalDeadline() {
        let id = UUID()
        let source = Source()
        var now: TimeInterval = 0
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in false },
            countDidChange: { counts.append($0) }, now: { now }, automaticallySchedule: false
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [id: UUID()])
        now = 2.4
        source.send(.active, observedAt: 1)
        source.send(.completed, observedAt: 2)
        #expect(tracker.count == 0)
        now = 2.9
        tracker.advance()
        #expect(tracker.count == 0)
        now = 3
        tracker.advance()
        #expect(counts == [1])
    }

    @Test func sourceDeliveryRecordsTheEndOfViewingBeforeDelayedCompletion() {
        let id = UUID()
        let source = Source()
        var now: TimeInterval = 0
        var viewed = true
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in viewed },
            countDidChange: { counts.append($0) }, now: { now }, automaticallySchedule: false
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [id: UUID()])
        now = 3
        viewed = false
        // Delivery can precede the coordinator's next visibility refresh.
        source.send(.active, observedAt: 1)
        source.send(.completed, observedAt: 2)
        #expect(counts.isEmpty)
    }

    @Test func untimestampedCompletionDoesNotReuseEarlierViewing() {
        let id = UUID()
        let source = Source()
        var now: TimeInterval = 0
        var viewed = true
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in viewed },
            countDidChange: { _ in }, now: { now }, automaticallySchedule: false
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [id: UUID()])
        now = 3
        viewed = false
        tracker.refreshVisibility()
        source.send(.active)
        source.send(.completed)
        #expect(tracker.count == 0)
        now = 4
        tracker.advance()
        #expect(tracker.count == 1)
    }

    @Test(arguments: [false, true])
    func viewingHistorySurvivesMovesButNotRemoval(removesSource: Bool) {
        let id = UUID()
        var source = Source()
        var now: TimeInterval = 0
        var viewed = true
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in viewed },
            countDidChange: { counts.append($0) }, now: { now }, automaticallySchedule: false
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [id: UUID()])
        now = 3
        viewed = false
        tracker.refreshVisibility()
        now = 4
        if removesSource {
            tracker.reconcile(owners: [:])
            source = Source()
        }
        tracker.reconcile(owners: [id: UUID()])
        now = 10
        source.send(.active, observedAt: 1)
        source.send(.completed, observedAt: 2)
        #expect(tracker.count == (removesSource ? 1 : 0))
        #expect(counts == (removesSource ? [1] : []))
    }

    @Test func metadataDeadlinePromotionAcknowledgesOtherViewedPanesBeforePublishing() {
        let firstID = UUID()
        let secondID = UUID()
        let first = Source()
        let second = Source()
        var now: TimeInterval = 0
        var viewed: UUID?
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { $0 == firstID ? first : second },
            isViewed: { $0 == viewed }, countDidChange: { counts.append($0) },
            now: { now }, automaticallySchedule: false
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [firstID: UUID(), secondID: UUID()])
        first.send(.active)
        first.send(.completed)
        now = 2
        viewed = firstID
        second.send(.active)
        #expect(counts.isEmpty)
        #expect(tracker.count == 0)
    }

    @Test func automaticDeadlinePublishesUnreadCompletion() async throws {
        let id = UUID()
        let source = Source()
        var counts: [Int] = []
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in false },
            countDidChange: { counts.append($0) }
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [id: UUID()])
        source.send(.active)
        source.send(.completed)
        #expect(tracker.count == 0)

        // Exercise the actual main-queue deadline without calling advance().
        try await Task.sleep(for: .milliseconds(1_200))

        #expect(tracker.count == 1)
        #expect(counts == [1])
    }

    @Test(arguments: [false, true])
    func automaticDeadlineCancellationCannotRestoreAttention(stopsMonitoring: Bool) async throws {
        let id = UUID()
        let source = Source()
        var counts: [Int] = []
        var clockReads = 0
        let tracker = SessionAttentionTracker(
            makeSource: { _ in source }, isViewed: { _ in false },
            countDidChange: { counts.append($0) },
            now: {
                clockReads += 1
                return ProcessInfo.processInfo.systemUptime
            }
        )
        defer { tracker.stop() }
        tracker.reconcile(owners: [id: UUID()])
        source.send(.active)
        source.send(.completed)
        if stopsMonitoring {
            tracker.stop()
            source.send(.paused)
        } else {
            source.send(.active)
        }
        let clockReadsAfterCancellation = clockReads

        try await Task.sleep(for: .milliseconds(1_200))

        #expect(tracker.count == 0)
        #expect(counts.isEmpty)
        // A cancelled work item must not even reenter the deadline path.
        #expect(clockReads == clockReadsAfterCancellation)
        #expect(source.stops == (stopsMonitoring ? 1 : 0))
    }
}
