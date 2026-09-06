import Foundation
import Testing
@testable import Ghostty

struct SessionPendingProcessActivityTests {
    @Test(arguments: [TerminalSessionTool.codex, .claudeCode])
    func fastStructuredRoundRetainsItsOriginalTimes(tool: TerminalSessionTool) {
        var pending = makePending()
        pending.observe(title: "Working", progressReport: .init(state: .indeterminate, progress: nil), observedAt: 1)
        pending.observe(title: "Working", progressReport: .init(state: .remove, progress: nil), observedAt: 2)

        #expect(pending.replay(for: tool) == [
            .init(tool: tool, status: .active, observedAt: 1),
            .init(tool: tool, status: .completed, observedAt: 2),
        ])
        #expect(pending.retainedProgress(for: tool)?.state == .remove)
    }

    @Test func repeatedSamplesCannotEvictTheStartOrMoveCompletionTime() {
        var pending = makePending()
        pending.observe(title: "Working", progressReport: nil, observedAt: 1)
        for index in 2...1000 {
            pending.observe(title: "⠙ project \(index)", progressReport: nil, observedAt: Double(index))
        }
        for index in 1001...2000 {
            pending.observe(title: "project", progressReport: nil, observedAt: Double(index))
        }

        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .active, observedAt: 1),
            .init(tool: .codex, status: .completed, observedAt: 1001),
        ])
    }

    @Test func initialCompletionNeverInventsAStart() {
        var pending = makePending()
        pending.observe(title: "project", progressReport: .init(state: .remove, progress: nil), observedAt: 4)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .completed, observedAt: 4),
        ])
    }

    @Test func initialProviderStateOnlyCarriesWithinTheSameProvider() {
        var pending = makePending(previousTool: .codex, previousStatus: .active)
        pending.observe(title: "project", progressReport: .init(state: .remove, progress: nil), observedAt: 4)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .active),
            .init(tool: .codex, status: .completed, observedAt: 4),
        ])
        #expect(pending.replay(for: .claudeCode) == [
            .init(tool: .claudeCode, status: .completed, observedAt: 4),
        ])
    }

    @Test func previouslyCompletedRoundRemainsUnarmed() {
        var pending = makePending(previousTool: .codex, previousStatus: .completed)
        pending.observe(title: "project", progressReport: nil, observedAt: 4)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .completed, observedAt: 4),
        ])
    }

    @Test func resolvedShellNeverReceivesAgentEvidence() {
        var pending = makePending()
        pending.observe(title: "Working", progressReport: .init(state: .pause, progress: nil), observedAt: 1)
        #expect(pending.replay(for: .terminal).isEmpty)
        #expect(pending.retainedProgress(for: .terminal) == nil)
    }

    @Test func resumedRoundDoesNotReplayAnEarlierApprovalOrCompletion() {
        var pending = makePending()
        pending.observe(title: "project", progressReport: .init(state: .pause, progress: nil), observedAt: 1)
        pending.observe(title: "project", progressReport: .init(state: .remove, progress: nil), observedAt: 2)
        pending.observe(title: "Working", progressReport: nil, observedAt: 3)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .active, observedAt: 3),
        ])
        #expect(pending.retainedProgress(for: .codex) == nil)
    }

    @Test func latestCompletedRoundUsesItsOwnStartAndCompletion() {
        var pending = makePending()
        for start in [1.0, 3.0] {
            pending.observe(title: "Working", progressReport: .init(state: .indeterminate, progress: nil), observedAt: start)
            pending.observe(title: "project", progressReport: .init(state: .remove, progress: nil), observedAt: start + 1)
        }
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .active, observedAt: 3),
            .init(tool: .codex, status: .completed, observedAt: 4),
        ])
    }

    @Test func answeredApprovalReplaysArmingWithoutHistoricalApproval() {
        var pending = makePending()
        pending.observe(title: "[ ! ] Action Required | project", progressReport: nil, observedAt: 1)
        pending.observe(title: "project", progressReport: nil, observedAt: 2)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .active, observedAt: 1),
            .init(tool: .codex, status: .completed, observedAt: 2),
        ])
    }

    @Test func pendingApprovalReplaysOnlyTheCurrentApproval() {
        var pending = makePending()
        pending.observe(title: "Working", progressReport: nil, observedAt: 1)
        pending.observe(title: "[ ! ] Action Required | project", progressReport: nil, observedAt: 2)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .paused, observedAt: 2),
        ])
    }

    @Test func failureClearsArmingAndALaterTitleCanStartANewRound() {
        var pending = makePending()
        pending.observe(title: "Working", progressReport: nil, observedAt: 1)
        pending.observe(title: "Working", progressReport: .init(state: .error, progress: nil), observedAt: 2)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .failed, observedAt: 2),
        ])
        pending.observe(title: "Thinking", progressReport: nil, observedAt: 3)
        pending.observe(title: "project", progressReport: nil, observedAt: 4)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .active, observedAt: 3),
            .init(tool: .codex, status: .completed, observedAt: 4),
        ])
    }

    @Test func titleBasedLatchResetIsProviderSpecific() {
        var pending = makePending()
        pending.observe(title: "project", progressReport: .init(state: .remove, progress: nil), observedAt: 1)
        pending.observe(title: "Working", progressReport: nil, observedAt: 2)
        #expect(pending.retainedProgress(for: .codex) == nil)
        #expect(pending.retainedProgress(for: .claudeCode)?.state == .remove)
    }

    @Test func failedRoundCannotReuseAnEarlierArmingWitness() {
        var pending = makePending(previousTool: .codex, previousStatus: .active)
        pending.observe(title: "project", progressReport: .init(state: .error, progress: nil), observedAt: 1)
        pending.observe(title: "project", progressReport: .init(state: .remove, progress: nil), observedAt: 2)
        #expect(pending.replay(for: .codex) == [
            .init(tool: .codex, status: .failed, observedAt: 1),
            .init(tool: .codex, status: .completed, observedAt: 2),
        ])
    }

    @Test func claudeIdleTitleCannotReplaceTheRequiredScreenAnalysis() {
        var pending = makePending()
        pending.observe(title: "⠙ Claude Code", progressReport: nil, observedAt: 1)
        pending.observe(title: "✳ Claude Code", progressReport: nil, observedAt: 2)
        #expect(pending.replay(for: .claudeCode) == [
            .init(tool: .claudeCode, status: .active, observedAt: 1),
        ])
    }

    private func makePending(
        previousTool: TerminalSessionTool = .terminal,
        previousStatus: TerminalSessionActivityStatus = .ready
    ) -> SessionPendingProcessActivity {
        SessionPendingProcessActivity(processID: 42, previousTool: previousTool, previousStatus: previousStatus)
    }
}
