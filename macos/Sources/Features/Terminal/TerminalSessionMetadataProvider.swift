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
