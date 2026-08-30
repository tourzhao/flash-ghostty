import Foundation
import GhosttyKit

extension TerminalSessionTool {
    static func detect(
        fromDynamicTitle title: String,
        foregroundProcessName: String? = nil
    ) -> Self {
        TerminalSessionMetadataProviders.tool(
            dynamicTitle: title,
            foregroundProcessName: foregroundProcessName
        )
    }
}

/// The small, sendable result of scanning the terminal's active screen at the
/// bottom of scrollback. Expensive text parsing happens on the metadata queue;
/// the main actor only applies these facts to the latest title/progress state.
struct TerminalSessionVisibleContentsAnalysis: Equatable, Sendable {
    let requiresUserInput: Bool
    let lastInstruction: String?
}

enum TerminalSessionVisibleContentsAnalyzer {
    static func analyze(
        tool: TerminalSessionTool,
        visibleContents: String
    ) -> TerminalSessionVisibleContentsAnalysis {
        TerminalSessionVisibleContentsAnalysis(
            requiresUserInput: tool == .claudeCode &&
                ClaudeCodeSessionMetadataProvider.visibleTailRequiresInput(visibleContents),
            lastInstruction: TerminalSessionMetadataProviders.lastInstruction(
                tool: tool,
                visibleContents: visibleContents
            )
        )
    }
}

/// Provider-specific terminal conventions are isolated behind this protocol so
/// adding another agent does not add branches to the sidebar or window controller.
private protocol TerminalSessionMetadataProvider {
    var tool: TerminalSessionTool { get }

    func matches(dynamicTitle: String, foregroundProcessName: String?) -> Bool

    func status(
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus

    func lastInstruction(visibleContents: String) -> String?
}

private struct CodexSessionMetadataProvider: TerminalSessionMetadataProvider {
    let tool = TerminalSessionTool.codex

    private static let spinnerFrames = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    private static let activeTitles: Set<String> = [
        "starting",
        "working",
        "waiting",
        "thinking",
    ]

    func matches(dynamicTitle: String, foregroundProcessName: String?) -> Bool {
        if let foregroundTool = TerminalSessionMetadataProviders
            .foregroundTool(foregroundProcessName) {
            return foregroundTool == tool
        }
        guard TerminalSessionMetadataProviders
            .allowsTitleFallback(foregroundProcessName) else { return false }

        let title = TerminalSessionMetadataProviders.normalizedTitle(dynamicTitle)
        return title == "codex" || title.hasPrefix("codex ")
    }

    func status(
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        let title = dynamicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.lowercased()

        if normalizedTitle.hasPrefix("[ ! ] action required") ||
            normalizedTitle.hasPrefix("[ . ] action required") {
            return .paused
        }

        if title.first.map(Self.spinnerFrames.contains) == true ||
            Self.activeTitles.contains(normalizedTitle) {
            return .active
        }

        return TerminalSessionMetadataProviders.idleStatus(after: previous)
    }

    func lastInstruction(visibleContents: String) -> String? {
        TerminalSessionInstructionParser.lastInstruction(
            prefix: "›",
            visibleContents: visibleContents
        )
    }
}

private struct ClaudeCodeSessionMetadataProvider: TerminalSessionMetadataProvider {
    let tool = TerminalSessionTool.claudeCode

    private static let spinnerFrames = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    func matches(dynamicTitle: String, foregroundProcessName: String?) -> Bool {
        if let foregroundTool = TerminalSessionMetadataProviders
            .foregroundTool(foregroundProcessName) {
            return foregroundTool == tool
        }
        guard TerminalSessionMetadataProviders
            .allowsTitleFallback(foregroundProcessName) else { return false }

        let titleWords = TerminalSessionMetadataProviders.words(in: dynamicTitle)
        let title = TerminalSessionMetadataProviders.normalizedTitle(dynamicTitle)
        return title == "claude" || title == "claude-code" ||
            titleWords.elementsEqual(["claude", "code"]) ||
            (titleWords.suffix(2).elementsEqual(["claude", "code"]) &&
                titleWords.count <= 3)
    }

    func status(
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        let title = dynamicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // A live spinner is a current provider signal. Permission text can
        // remain on the active screen after the user answers it, so it must not
        // override evidence that Claude has resumed work.
        if title.first.map(Self.spinnerFrames.contains) == true {
            return .active
        }

        if Self.visibleTailRequiresInput(visibleContents) {
            return .paused
        }

        return TerminalSessionMetadataProviders.idleStatus(after: previous)
    }

    func lastInstruction(visibleContents: String) -> String? {
        TerminalSessionInstructionParser.lastInstruction(
            prefix: "❯",
            visibleContents: visibleContents
        )
    }

    fileprivate static func visibleTailRequiresInput(_ contents: String) -> Bool {
        let tail = contents
            .split(whereSeparator: { $0.isNewline })
            .suffix(18)
            .joined(separator: "\n")
            .lowercased()

        guard !tail.isEmpty else { return false }

        if tail.contains("claude needs your permission") ||
            tail.contains("waiting for your input") ||
            tail.contains("would you like to proceed?") ||
            tail.contains("allow for this session") ||
            tail.contains("yes, and don't ask again") ||
            tail.contains("yes, and allow") {
            return true
        }

        let hasQuestion = tail.contains("do you want to ") ||
            tail.contains("do you want to proceed?")
        let hasYesAndNo = tail.contains("yes") && tail.contains("no")
        let hasSelectionFooter = tail.contains("esc to cancel") &&
            (tail.contains("enter to select") || hasYesAndNo)
        return (hasQuestion && hasYesAndNo) || hasSelectionFooter
    }
}

private enum TerminalSessionMetadataProviders {
    private static let providers: [TerminalSessionMetadataProvider] = [
        CodexSessionMetadataProvider(),
        ClaudeCodeSessionMetadataProvider(),
    ]

    static func tool(
        dynamicTitle: String,
        foregroundProcessName: String?
    ) -> TerminalSessionTool {
        providers.first {
            $0.matches(
                dynamicTitle: dynamicTitle,
                foregroundProcessName: foregroundProcessName
            )
        }?.tool ?? .terminal
    }

    static func status(
        tool: TerminalSessionTool,
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        guard let provider = providers.first(where: { $0.tool == tool }) else {
            return .ready
        }

        return provider.status(
            dynamicTitle: dynamicTitle,
            visibleContents: visibleContents,
            previous: previous
        )
    }

    static func lastInstruction(
        tool: TerminalSessionTool,
        visibleContents: String
    ) -> String? {
        providers.first(where: { $0.tool == tool })?
            .lastInstruction(visibleContents: visibleContents)
    }

    static func foregroundTool(_ value: String?) -> TerminalSessionTool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let url = URL(fileURLWithPath: value)
        let executableWords = words(in: url.lastPathComponent)
        if executableWords.contains("codex") { return .codex }
        if executableWords.contains("claude") { return .claudeCode }

        // Some standalone installers launch a version-named executable below
        // `share/<provider>/versions`. Restrict this fallback to the distribution
        // layout: arbitrary path components such as `/Users/claude` are not
        // provider evidence.
        let pathComponents = url.pathComponents.map { $0.lowercased() }
        if pathComponents.count >= 3 {
            for index in 1..<(pathComponents.count - 1) {
                guard pathComponents[index - 1] == "share",
                      pathComponents[index + 1] == "versions" else { continue }
                switch pathComponents[index] {
                case "codex": return .codex
                case "claude": return .claudeCode
                default: continue
                }
            }
        }
        return nil
    }

    /// Node-based agent CLIs often expose only their runtime as the foreground
    /// process. In that case a strict, provider-owned terminal title is the best
    /// available evidence. Ordinary shells and editors remain authoritative so
    /// a stale title cannot keep an agent icon after the agent exits.
    static func allowsTitleFallback(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return true }
        let executable = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        return ["node", "nodejs", "npm", "npx", "bun", "deno"].contains(executable)
    }

    static func normalizedTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func words(in value: String) -> [Substring] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
    }

    static func idleStatus(
        after previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        switch previous {
        case .active, .paused:
            return .completed
        case .completed, .failed:
            return previous
        case .ready:
            return .ready
        }
    }
}

/// Derives an agent activity state from structured terminal progress first,
/// then delegates provider-specific fallbacks to the matching provider.
struct TerminalSessionActivityClassifier {
    static func retainedProgressReport(
        current: Ghostty.Action.ProgressReport?,
        incoming: Ghostty.Action.ProgressReport?
    ) -> Ghostty.Action.ProgressReport? {
        incoming ?? current
    }

    static func status(
        tool: TerminalSessionTool,
        dynamicTitle: String,
        progressReport: Ghostty.Action.ProgressReport?,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        if let progressReport {
            switch progressReport.state {
            case .set, .indeterminate:
                return .active
            case .pause:
                return .paused
            case .error:
                return .failed
            case .remove:
                return .completed
            }
        }

        return TerminalSessionMetadataProviders.status(
            tool: tool,
            dynamicTitle: dynamicTitle,
            visibleContents: visibleContents,
            previous: previous
        )
    }

    /// Applies pre-parsed active-screen facts without scanning a terminal-sized
    /// string on the main actor. This intentionally preserves provider
    /// precedence: structured progress, then an active title, then a Claude
    /// permission prompt, and finally the provider's idle transition.
    static func status(
        tool: TerminalSessionTool,
        dynamicTitle: String,
        progressReport: Ghostty.Action.ProgressReport?,
        visibleContentsAnalysis: TerminalSessionVisibleContentsAnalysis,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        let contentIndependent = status(
            tool: tool,
            dynamicTitle: dynamicTitle,
            progressReport: progressReport,
            visibleContents: "",
            previous: previous
        )

        if progressReport != nil || contentIndependent == .active {
            return contentIndependent
        }
        if tool == .claudeCode && visibleContentsAnalysis.requiresUserInput {
            return .paused
        }
        return contentIndependent
    }

    /// Returns a status only when structured progress or the provider title is
    /// sufficient without synchronously reading the terminal's active screen.
    static func statusWithoutVisibleContentsIfDefinitive(
        tool: TerminalSessionTool,
        dynamicTitle: String,
        progressReport: Ghostty.Action.ProgressReport?,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus? {
        let result = status(
            tool: tool,
            dynamicTitle: dynamicTitle,
            progressReport: progressReport,
            visibleContents: "",
            previous: previous
        )
        if progressReport != nil || result == .active {
            return result
        }

        return nil
    }

    /// Completed and failed reports remain latched, so Claude's active screen can
    /// still reveal that a new active or paused turn has begun.
    static func requiresVisibleContentsFallback(
        tool: TerminalSessionTool,
        progressReport: Ghostty.Action.ProgressReport?
    ) -> Bool {
        guard tool == .claudeCode else { return false }
        guard let progressReport else { return true }
        return progressReport.state == .remove || progressReport.state == .error
    }
}

struct TerminalSessionInstructionExtractor {
    static func lastInstruction(
        tool: TerminalSessionTool,
        visibleContents: String
    ) -> String? {
        TerminalSessionMetadataProviders.lastInstruction(
            tool: tool,
            visibleContents: visibleContents
        )
    }
}
