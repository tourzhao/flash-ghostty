import Foundation
import Testing
@testable import Ghostty

@Suite
struct SessionAttentionStateTests {
    @Test(arguments: [TerminalSessionTool.codex, .claudeCode])
    func unobservedCompletionDoesNotCreateAttention(tool: TerminalSessionTool) {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: tool, status: .completed, isViewed: false, now: 0)
        state.advance(to: 100)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)

        state.update(surfaceID: surface, tool: tool, status: .ready, isViewed: false, now: 101)
        state.update(surfaceID: surface, tool: tool, status: .completed, isViewed: false, now: 102)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    @Test(arguments: [TerminalSessionTool.codex, .claudeCode])
    func completionNeedsAnObservedRoundAndTheFullDelay(tool: TerminalSessionTool) {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: tool, status: .active, isViewed: false, now: 10)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)

        state.update(surfaceID: surface, tool: tool, status: .completed, isViewed: false, now: 11)
        #expect(state.count == 0)
        #expect(state.nextDeadline == 12)
        state.advance(to: 11.999)
        #expect(state.count == 0)
        state.advance(to: 12)
        #expect(state.count == 1)
        #expect(state.nextDeadline == nil)
        state.advance(to: 100)
        #expect(state.count == 1)
    }

    @Test
    func repeatedCompletedSamplesDoNotPostponeOrRearmCompletion() {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1.5)
        #expect(state.nextDeadline == 2)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 2)
        #expect(state.count == 1)

        state.markViewed(surfaceID: surface)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 3)
        state.advance(to: 100)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    @Test
    func transientCompletionIsCancelledByResumedActivityAndTheNextRoundCanFinish() {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 1)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 2)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 2.5)
        #expect(state.nextDeadline == nil)
        state.advance(to: 3)
        #expect(state.count == 0)

        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 4)
        #expect(state.nextDeadline == 5)
        state.advance(to: 5)
        #expect(state.count == 1)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 6)
        #expect(state.count == 0)
    }

    @Test(arguments: [TerminalSessionTool.codex, .claudeCode])
    func approvalAppearsImmediatelyAndViewingDoesNotClearIt(tool: TerminalSessionTool) {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: tool, status: .paused, isViewed: true, now: 0)
        #expect(state.count == 1)
        #expect(state.nextDeadline == nil)
        state.markViewed(surfaceID: surface)
        state.update(surfaceID: surface, tool: tool, status: .paused, isViewed: true, now: 1)
        state.advance(to: 100)
        #expect(state.count == 1)

        state.update(surfaceID: surface, tool: tool, status: .active, isViewed: true, now: 101)
        #expect(state.count == 0)
        state.update(surfaceID: surface, tool: tool, status: .completed, isViewed: false, now: 102)
        state.advance(to: 103)
        #expect(state.count == 1)
    }

    @Test
    func pausedRoundCanFinishAndApprovalBecomesDelayedCompletion() {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .claudeCode, status: .paused, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .claudeCode, status: .completed, isViewed: false, now: 1)
        #expect(state.count == 0)
        #expect(state.nextDeadline == 2)
        state.advance(to: 2)
        #expect(state.count == 1)
    }

    @Test
    func pausedStateReplacesPendingCompletion() {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        state.update(surfaceID: surface, tool: .codex, status: .paused, isViewed: false, now: 1.5)
        #expect(state.count == 1)
        #expect(state.nextDeadline == nil)
        state.markViewed(surfaceID: surface)
        state.advance(to: 100)
        #expect(state.count == 1)
    }

    @Test
    func completionAlreadyViewedIsConsumedWithoutAnUnreadAlert() {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: true, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: true, now: 1)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 2)
        state.advance(to: 100)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    @Test(arguments: [false, true])
    func viewingPendingCompletionCancelsItWithoutRearming(useMetadata: Bool) {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .claudeCode, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .claudeCode, status: .completed, isViewed: false, now: 1)
        if useMetadata {
            state.update(surfaceID: surface, tool: .claudeCode, status: .completed, isViewed: true, now: 1.5)
        } else {
            state.markViewed(surfaceID: surface)
        }
        #expect(state.nextDeadline == nil)
        state.advance(to: 2)
        state.update(surfaceID: surface, tool: .claudeCode, status: .completed, isViewed: false, now: 3)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    @Test
    func viewingActivePaneDoesNotAcknowledgeAFutureUnseenCompletion() {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: true, now: 0)
        state.markViewed(surfaceID: surface)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        state.advance(to: 2)
        #expect(state.count == 1)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: true, now: 3)
        #expect(state.count == 0)
    }

    @Test(arguments: [TerminalSessionActivityStatus.ready, .failed])
    func terminalRoundStatesClearApprovalAndDisarm(status: TerminalSessionActivityStatus) {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .paused, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: status, isViewed: false, now: 1)
        #expect(state.count == 0)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 2)
        state.advance(to: 3)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    @Test(arguments: [TerminalSessionActivityStatus.ready, .failed], [false, true])
    func terminalRoundStatesClearPendingAndUnreadCompletions(
        status: TerminalSessionActivityStatus,
        matureFirst: Bool
    ) {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        if matureFirst { state.advance(to: 2) }
        state.update(surfaceID: surface, tool: .codex, status: status, isViewed: false, now: 3)
        state.advance(to: 100)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    @Test(arguments: [TerminalSessionTool.claudeCode, .terminal])
    func changingToolClearsAndDisarmsThePreviousProvider(tool: TerminalSessionTool) {
        let surface = UUID()
        var state = makeState(surface: surface)
        state.update(surfaceID: surface, tool: .codex, status: .paused, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: tool, status: .completed, isViewed: false, now: 1)
        state.advance(to: 2)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 3)
        #expect(state.nextDeadline == nil)

        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 4)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 5)
        state.advance(to: 6)
        #expect(state.count == 1)
    }

    @Test
    func ordinaryTerminalNeverCreatesAttention() {
        let surface = UUID()
        var state = makeState(surface: surface)
        for (index, status) in [TerminalSessionActivityStatus.active, .paused, .completed, .failed].enumerated() {
            state.update(surfaceID: surface, tool: .terminal, status: status, isViewed: false, now: Double(index))
        }
        state.advance(to: 100)
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    @Test
    func multiplePanesAndReasonsCountTheirSessionOnceAndViewingOnlyReadsOnePane() {
        let first = UUID()
        let second = UUID()
        let approval = UUID()
        let session = UUID()
        var state = SessionAttentionState()
        state.reconcile(owners: [first: session, second: session, approval: session])
        for surface in [first, second] {
            state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
            state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        }
        state.update(surfaceID: approval, tool: .claudeCode, status: .paused, isViewed: false, now: 1)
        state.advance(to: 2)
        #expect(state.count == 1)

        state.markViewed(surfaceID: first)
        #expect(state.count == 1)
        state.update(surfaceID: approval, tool: .claudeCode, status: .ready, isViewed: true, now: 3)
        #expect(state.count == 1)
        state.markViewed(surfaceID: second)
        #expect(state.count == 0)
    }

    @Test
    func movingAPanePreservesPendingAndUnreadStateAndRecountsOwners() {
        let first = UUID()
        let second = UUID()
        let originalSession = UUID()
        let movedSession = UUID()
        var state = SessionAttentionState()
        state.reconcile(owners: [first: originalSession, second: originalSession])
        state.update(surfaceID: first, tool: .codex, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: first, tool: .codex, status: .completed, isViewed: false, now: 1)
        state.update(surfaceID: second, tool: .claudeCode, status: .paused, isViewed: false, now: 1)

        state.reconcile(owners: [first: movedSession, second: originalSession])
        #expect(state.nextDeadline == 2)
        state.advance(to: 2)
        #expect(state.count == 2)
        state.reconcile(owners: [first: originalSession, second: originalSession])
        #expect(state.count == 1)
        state.reconcile(owners: [first: movedSession])
        #expect(state.count == 1)
        state.markViewed(surfaceID: first)
        #expect(state.count == 0)
    }

    @Test
    func closingPanesDropsDeadlinesAndStaleCallbacksCannotRecreateState() {
        let surface = UUID()
        let owner = UUID()
        var state = SessionAttentionState()
        state.reconcile(owners: [surface: owner])
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        state.reconcile(owners: [:])
        #expect(state.nextDeadline == nil)
        state.update(surfaceID: surface, tool: .codex, status: .paused, isViewed: false, now: 2)
        state.markViewed(surfaceID: UUID())
        state.advance(to: 100)
        #expect(state.count == 0)

        // Even if an identifier is later reintroduced, removed rounds stay gone.
        state.reconcile(owners: [surface: owner])
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 101)
        #expect(state.nextDeadline == nil)
        #expect(state.count == 0)
    }

    @Test
    func deadlineTracksTheEarliestUnacknowledgedCompletion() {
        let first = UUID()
        let second = UUID()
        var state = SessionAttentionState(completionDelay: 2)
        state.reconcile(owners: [first: UUID(), second: UUID()])
        for surface in [first, second] {
            state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
        }
        state.update(surfaceID: first, tool: .codex, status: .completed, isViewed: false, now: 1)
        state.update(surfaceID: second, tool: .codex, status: .completed, isViewed: false, now: 2)
        #expect(state.nextDeadline == 3)
        state.markViewed(surfaceID: first)
        #expect(state.nextDeadline == 4)
        state.advance(to: 4)
        #expect(state.count == 1)
        #expect(state.nextDeadline == nil)
    }

    @Test
    func zeroDelayAndMetadataTimeAdvanceDoNotNeedATimerTick() {
        let surface = UUID()
        var state = SessionAttentionState(completionDelay: 0)
        state.reconcile(owners: [surface: UUID()])
        state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
        state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        #expect(state.count == 1)
        #expect(state.nextDeadline == nil)
    }

    @Test
    func hundredSessionsRemainDistinctAndClosingOrReadingOneDoesNotClearTheOthers() {
        let surfaces = (0..<100).map { _ in UUID() }
        var owners = Dictionary(uniqueKeysWithValues: surfaces.map { ($0, UUID()) })
        var state = SessionAttentionState()
        state.reconcile(owners: owners)
        for surface in surfaces {
            state.update(surfaceID: surface, tool: .codex, status: .active, isViewed: false, now: 0)
            state.update(surfaceID: surface, tool: .codex, status: .completed, isViewed: false, now: 1)
        }
        #expect(state.count == 0)
        #expect(state.nextDeadline == 2)
        state.advance(to: 2)
        #expect(state.count == 100)
        state.markViewed(surfaceID: surfaces[0])
        #expect(state.count == 99)
        owners.removeValue(forKey: surfaces[1])
        state.reconcile(owners: owners)
        #expect(state.count == 98)
        state.reconcile(owners: [:])
        #expect(state.count == 0)
        #expect(state.nextDeadline == nil)
    }

    private func makeState(surface: UUID) -> SessionAttentionState {
        var state = SessionAttentionState()
        state.reconcile(owners: [surface: UUID()])
        return state
    }
}
