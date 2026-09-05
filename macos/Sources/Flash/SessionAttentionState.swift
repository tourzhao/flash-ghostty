import Foundation

/// Tracks attention for live agent panes, counting each owning session once.
/// Time and visibility come from the caller so this state has no UI or timer
/// dependencies and can be reconciled before handling asynchronous callbacks.
struct SessionAttentionState {
    private enum Completion {
        case none
        case pending(deadline: TimeInterval)
        case unread
    }

    private struct SurfaceState {
        var tool: TerminalSessionTool
        var armed = false
        var approval = false
        var completion: Completion = .none

        var needsAttention: Bool {
            if approval { return true }
            if case .unread = completion { return true }
            return false
        }
    }

    private let completionDelay: TimeInterval
    private var owners: [UUID: UUID] = [:]
    private var surfaces: [UUID: SurfaceState] = [:]

    init(completionDelay: TimeInterval = 1.0) {
        precondition(completionDelay.isFinite && completionDelay >= 0)
        self.completionDelay = completionDelay
    }

    var count: Int {
        var sessions: Set<UUID> = []
        for (surfaceID, state) in surfaces where state.needsAttention {
            if let owner = owners[surfaceID] { sessions.insert(owner) }
        }
        return sessions.count
    }

    var nextDeadline: TimeInterval? {
        surfaces.values.compactMap { state in
            if case .pending(let deadline) = state.completion { return deadline }
            return nil
        }.min()
    }

    /// A pane keeps its round and unread state when it moves between sessions.
    /// Removed panes lose their state, including any pending completion timer.
    mutating func reconcile(owners: [UUID: UUID]) {
        self.owners = owners
        surfaces = surfaces.filter { owners[$0.key] != nil }
    }

    mutating func update(
        surfaceID: UUID,
        tool: TerminalSessionTool,
        status: TerminalSessionActivityStatus,
        isViewed: Bool,
        now: TimeInterval
    ) {
        // Late metadata from closed panes must not recreate attention state.
        guard owners[surfaceID] != nil else { return }
        defer { advance(to: now) }

        guard tool == .codex || tool == .claudeCode else {
            surfaces.removeValue(forKey: surfaceID)
            return
        }

        var state = surfaces[surfaceID] ?? SurfaceState(tool: tool)
        if state.tool != tool { state = SurfaceState(tool: tool) }

        switch status {
        case .active:
            state.armed = true
            state.approval = false
            state.completion = .none

        case .paused:
            state.armed = true
            state.approval = true
            state.completion = .none

        case .completed:
            state.approval = false
            // Consume this round even if the pane is already viewed. A
            // repeated completed sample cannot re-arm a read completion.
            if state.armed {
                state.armed = false
                state.completion = isViewed ? .none : .pending(deadline: now + completionDelay)
            } else if isViewed {
                state.completion = .none
            }

        case .ready, .failed:
            state.armed = false
            state.approval = false
            state.completion = .none
        }

        surfaces[surfaceID] = state
    }

    /// Acknowledges this pane's completion only. Approval still requires the
    /// agent to resume or leave its paused state, even while the pane is shown.
    mutating func markViewed(surfaceID: UUID) {
        guard var state = surfaces[surfaceID] else { return }
        state.completion = .none
        surfaces[surfaceID] = state
    }

    mutating func advance(to now: TimeInterval) {
        for (surfaceID, var state) in surfaces {
            guard case .pending(let deadline) = state.completion, deadline <= now else { continue }
            state.completion = .unread
            surfaces[surfaceID] = state
        }
    }
}
