import Foundation

enum TerminalSessionTool: Equatable, Hashable, Sendable {
    case codex
    case claudeCode
    case terminal
}

/// The user-facing activity state for a sidebar session.
///
/// `ready` is intentionally distinct from `completed`: an agent starts ready,
/// and only becomes completed after an observed active or paused turn ends.
enum TerminalSessionActivityStatus: Equatable, Sendable {
    case ready
    case active
    case paused
    case completed
    case failed
}

/// A coherent provider/activity value for consumers that must not observe one
/// provider's status paired with another provider during a binding transition.
struct TerminalSessionActivitySnapshot: Equatable, Sendable {
    let tool: TerminalSessionTool
    let status: TerminalSessionActivityStatus
    /// Original monotonic observation time when provider discovery delays delivery.
    let observedAt: TimeInterval?

    init(
        tool: TerminalSessionTool,
        status: TerminalSessionActivityStatus,
        observedAt: TimeInterval? = nil
    ) {
        self.tool = tool
        self.status = status
        self.observedAt = observedAt
    }
}
